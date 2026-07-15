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
    ) -> ChatAnchorRemoteFetchPlan? {
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
    ) -> ChatAnchorRemoteFetchPlan? {
        guard let sourceDate = anchor.sourceDate else { return nil }
        let start = Date(timeIntervalSince1970: sourceDate.timeIntervalSince1970 - windowPadding)
        let end = Date(timeIntervalSince1970: sourceDate.timeIntervalSince1970 + windowPadding)
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

enum ChatAnchorContextCoverageBoundary: Equatable {
    case complete
    case knownGap
    case unknown
}

struct ChatAnchorContextCoverage: Equatable {
    let olderLocalCount: Int
    let newerLocalCount: Int
    let olderBoundary: ChatAnchorContextCoverageBoundary
    let newerBoundary: ChatAnchorContextCoverageBoundary
}

enum ChatAnchorContextPrefetchPolicy {
    static func plan(
        observerIndex: Int,
        totalCount: Int,
        pageSize: Int,
        archivedId: String?
    ) -> ChatAnchorContextPrefetchPlan {
        plan(
            coverage: ChatAnchorContextCoverage(
                olderLocalCount: max(0, observerIndex),
                newerLocalCount: max(0, totalCount - observerIndex - 1),
                olderBoundary: .unknown,
                newerBoundary: .unknown
            ),
            pageSize: pageSize,
            archivedId: archivedId
        )
    }

    static func plan(
        coverage: ChatAnchorContextCoverage,
        pageSize: Int,
        archivedId: String?
    ) -> ChatAnchorContextPrefetchPlan {
        guard let archivedId,
              archivedId.isNotEmpty else {
            return ChatAnchorContextPrefetchPlan(newerPageSize: nil, olderPageSize: nil)
        }

        let targetContextPerSide = max(1, pageSize / 2)
        let newerDeficit = coverage.newerLocalCount < targetContextPerSide &&
            coverage.newerBoundary != .complete
            ? min(targetContextPerSide - coverage.newerLocalCount, targetContextPerSide)
            : 0
        let olderDeficit = coverage.olderLocalCount < targetContextPerSide &&
            coverage.olderBoundary != .complete
            ? min(targetContextPerSide - coverage.olderLocalCount, targetContextPerSide)
            : 0

        return ChatAnchorContextPrefetchPlan(
            newerPageSize: newerDeficit > 0 ? newerDeficit : nil,
            olderPageSize: olderDeficit > 0 ? olderDeficit : nil
        )
    }

    static func coverage(
        observerIndex: Int,
        totalCount: Int,
        targetArchivedId: String,
        archiveState: ChatArchiveStateSnapshot
    ) -> ChatAnchorContextCoverage {
        let targetDate = ChatInitialPositionPolicy.archiveDate(from: targetArchivedId)
        let hasKnownOlderGap = targetDate.map { targetDate in
            archiveState.knownGaps.contains { gap in
                guard let newerEdge = ChatInitialPositionPolicy.archiveDate(
                    from: gap.newerRangeOldestArchiveId
                ) else { return false }
                return newerEdge <= targetDate
            }
        } ?? false
        let hasKnownNewerGap = targetDate.map { targetDate in
            archiveState.knownGaps.contains { gap in
                guard let olderEdge = ChatInitialPositionPolicy.archiveDate(
                    from: gap.olderRangeNewestArchiveId
                ) else { return false }
                return olderEdge >= targetDate
            }
        } ?? archiveState.hasKnownNewerGap

        return ChatAnchorContextCoverage(
            olderLocalCount: max(0, observerIndex),
            newerLocalCount: max(0, totalCount - observerIndex - 1),
            olderBoundary: hasKnownOlderGap
                ? .knownGap
                : (archiveState.fullArchiveLoaded ? .complete : .unknown),
            newerBoundary: hasKnownNewerGap
                ? .knownGap
                : (archiveState.newerLiveEdgeReached ? .complete : .unknown)
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

enum ChatInitialAutomaticOpenPolicy {
    static func shouldOpenUnreadBoundaryOnChatOpen() -> Bool {
        true
    }

    static func shouldRestoreSavedVisiblePositionOnChatOpen() -> Bool {
        true
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
        true
    }

    static func shouldHonorMessageAnchorRequest(source: ChatOpenMessageRequestSource) -> Bool {
        if source == .search ||
            source == .initialUnreadBoundary ||
            source == .savedVisiblePosition ||
            source == .external ||
            source == .directOpenAtMessage ||
            source == .mediaGallery {
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
        residentPrimaryPositions: [String: Int],
        observerCount: Int
    ) -> Bool {
        guard isNearBottom,
              observerCount > 0,
              let lastRealDatasourcePrimary,
              let observerIndex = residentPrimaryPositions[lastRealDatasourcePrimary] else {
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
    let transactionToken: ChatAnchorTransactionToken
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

    init(
        request: ChatOpenMessageRequest,
        transactionToken: ChatAnchorTransactionToken = ChatAnchorTransactionToken(),
        usesBootstrapLoading: Bool = false
    ) {
        self.request = request
        self.transactionToken = transactionToken
        self.usesBootstrapLoading = usesBootstrapLoading
    }
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
           messageId.isNotEmpty {
            let matches = anchorableItems.filter {
                $0.element.messageId == messageId
                    && (anchor.authorId?.isNotEmpty != true || $0.element.groupchatAuthorId == anchor.authorId)
            }
            if matches.count == 1, let match = matches.first {
                return match.offset
            }
        }

        if let sourceDate = anchor.sourceDate,
           let fingerprint = LastChatsSearchFingerprint.normalize(anchor.bodyFingerprint) {
            let matches = anchorableItems.filter {
                abs($0.element.sentDate.timeIntervalSince(sourceDate)) <= LastChatsSearchLocalResolver.dateTolerance
                    && (anchor.authorId?.isNotEmpty != true || $0.element.groupchatAuthorId == anchor.authorId)
                    && LastChatsSearchFingerprint.normalize(searchBody(in: $0.element.kind)) == fingerprint
            }
            if matches.count == 1, let match = matches.first {
                return match.offset
            }
        }

        return nil
    }

    private static func searchBody(in kind: MessageKind) -> String? {
        switch kind {
        case .attributedText(let value), .system(let value), .initial(let value):
            return value.string
        case .emoji(let value):
            return value
        case .sticker, .call, .skeleton, .date, .unread:
            return nil
        }
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
        xabberInputView.searchPanel.applyRenderState(renderState)
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
            searchBar.resignFirstResponder()
            searchInputBar.endEditing(true)
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
        applyChatDatasource(
            datasource,
            mode: .fullReload(keepOffset: true),
            animated: false,
            suppressDefaultBottomScroll: true
        )
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
            unregisterRemoteHistoryPersistenceSource(queryId: currentSearchQueryId)
            searchSessionGenerationByQueryId.removeValue(forKey: currentSearchQueryId)
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
            xabberInputView.searchPanel.applyRenderState(panelState)
        }
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

    private var inChatSearchResultMappingContext: ChatSearchResultMappingContext {
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
            xabberInputView.searchPanel.applyRenderState(.idle)
            return
        }

        guard searchMessagesQueue.isNotEmpty else {
            if xabberInputView.searchPanel.isInLoadingState {
                xabberInputView.searchPanel.applyRenderState(.loading)
            } else {
                xabberInputView.searchPanel.applyRenderState(.emptyResults)
            }
            return
        }

        let currentIndex = currentSearchResultIndexForPanel()
        xabberInputView.searchPanel.applyRenderState(
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
        xabberInputView.searchPanel.applyRenderState(
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
        timelineInteractionState.locked ||
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

        if timelineInteractionState.locked || searchResultNavigationState.isBusy {
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

        if let executionState = self.activeAnchorExecutionState,
           executionState.request == request,
           executionState.contextPrefetchPendingQueryIds.isNotEmpty {
            self.pendingOpenMessageRequest = request
            self.activeAnchorExecutionHooks = hooks ?? self.activeAnchorExecutionHooks
            self.syncAnchorExecutionFlags()
            return
        }
        if let executionState = self.activeAnchorExecutionState,
           executionState.request != request {
            self.cancelActiveAnchorExecution(
                token: executionState.transactionToken,
                failure: .superseded,
                invokeFailureHook: false
            )
        }
        if self.shouldRetargetPendingInitialFirstFrame {
            if request.source == .search {
                self.markSearchResultNavigationLoadingContext(for: request)
                self.setSearchResultsPanelContextLoading(true)
            }
            self.pendingOpenMessageRequest = request
            self.activeAnchorExecutionHooks = hooks
            self.syncAnchorExecutionFlags()
            self.loadInitialDatasource(performPendingOpenMessageRequest: false)
            return
        }
        if self.performLoadedOpenMessageRequestIfPossible(request, hooks: hooks) {
            return
        }
        if request.source == .search {
            self.markSearchResultNavigationLoadingContext(for: request)
            self.setSearchResultsPanelContextLoading(true)
        }
        self.pendingOpenMessageRequest = request
        self.activeAnchorExecutionHooks = hooks
        self.syncAnchorExecutionFlags()
        self.performPendingOpenMessageRequestIfNeeded(trigger: .manual)
    }

    private var shouldRetargetPendingInitialFirstFrame: Bool {
        guard self.isViewLoaded,
              self.timelineSession != nil,
              self.initialFirstContentApplyCount == 0 else {
            return false
        }
        return !self.datasource.contains { !$0.isFakeMessage }
    }

    private func handleSuppressedOpenMessageRequest(animated: Bool) {
        self.requestForceLatestOpen(animated: animated)
    }

    internal func clearSuppressedOpenMessageRequestState() {
        if let executionState = self.activeAnchorExecutionState {
            self.cancelActiveAnchorExecution(
                token: executionState.transactionToken,
                failure: .superseded,
                invokeFailureHook: false
            )
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
        self.timelineInteractionState.unlock()
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
        let residentSnapshot = self.timelineSession?.snapshot
        let viewportCenterY = self.messagesCollectionView.contentOffset.y + (self.messagesCollectionView.bounds.height / 2)
        let isLiveBottom = ChatVisiblePositionPersistencePolicy.isLiveBottom(
            isNearBottom: self.isNearBottom(),
            lastRealDatasourcePrimary: self.lastRealDatasourceMessagePrimary(),
            residentPrimaryPositions: residentSnapshot?.residentIndex.primaryIndexByID ?? [:],
            observerCount: residentSnapshot?.items.count ?? 0
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
        if case .firstIncomingAfterBoundary(let boundaryArchivedId) = request.targetResolution {
            guard let target = self.timelineSession?.firstIncoming(
                afterArchiveBoundaryId: boundaryArchivedId
            ),
                  let section = self.datasourceSnapshot.primaryIndex[target.primary],
                  section < self.datasource.count else {
                return nil
            }
            return IndexPath(row: 0, section: section)
        }

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
            completion: { _ in completion?() }
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
        let executionState = self.ensureActiveAnchorExecutionState(for: request)
        let transactionToken = executionState.transactionToken
        let activeHooks = hooks ?? self.activeAnchorExecutionHooks
        self.activeAnchorExecutionHooks = activeHooks
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
            self.syncAnchorExecutionFlags()
            if self.prepareContextPrefetchIfNeeded(around: resolvedTarget, request: request) {
                if request.source == .search {
                    self.markSearchResultNavigationLoadingContext(for: request)
                    self.setSearchResultsPanelContextLoading(true)
                }
                return true
            }
        }

        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(true)
        self.timelineInteractionState.unlock()

        self.notifyAnchorPositioningStarted(token: transactionToken)
        self.positionMessage(
            primary: target.primary,
            archivedId: target.archivedId,
            highlight: request.highlight && !usesTransientHighlight,
            animated: activeHooks?.animatedScroll ?? false,
            preferredScrollDirection: request.source == .search ? activeHooks?.direction : nil,
            completion: { didPosition in
                guard didPosition else {
                    self.failActiveAnchorExecution(
                        token: transactionToken,
                        failure: .targetDeleted
                    )
                    return
                }
                guard self.anchorTransactionGate.accept(.scroll, token: transactionToken) == .accepted else {
                    return
                }
                if usesTransientHighlight {
                    self.applyTransientMessageHighlight(primary: target.primary)
                }
                self.scheduleMentionReadOnVisibleIfNeeded(
                    for: request,
                    positionedPrimary: target.primary
                )
                self.finishActiveAnchorExecution(token: transactionToken)
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
        for request: ChatOpenMessageRequest,
        residentSnapshot: ChatTimelineSessionSnapshot? = nil
    ) -> Int? {
        guard request.source == .savedVisiblePosition,
              let timelineSession = self.timelineSession else {
            return nil
        }
        let snapshot = residentSnapshot ?? timelineSession.snapshot

        guard let message = timelineSession.resolvedMessage(
            primary: request.anchor.messagePrimary,
            archivedId: request.anchor.archivedId,
            messageId: request.anchor.messageId
        ) else {
            return nil
        }
        return snapshot.residentIndex.index(primary: message.primary)
            ?? RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(message.archivedId)
                .flatMap { snapshot.residentIndex.index(archivedId: $0) }
            ?? snapshot.residentIndex.index(messageId: message.messageId)
    }

    internal func beginPreparedLocalFirstFrameAnchor(request: ChatOpenMessageRequest) {
        var executionState = ChatAnchorExecutionState(
            request: request,
            usesBootstrapLoading: false
        )
        executionState.isPositioning = true
        _ = self.anchorTransactionGate.begin(
            token: executionState.transactionToken,
            requestIdentity: self.anchorRequestIdentity(request)
        )
        self.activeAnchorExecutionState = executionState
        self.isApplyingBootstrapAnchorWindow = true
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(false)
        self.notifyAnchorPositioningStarted(token: executionState.transactionToken)
    }

    internal func finishPreparedLocalFirstFrameAnchor(
        request: ChatOpenMessageRequest,
        primary: String,
        archivedId: String?
    ) {
        if request.highlight {
            self.applyTransientMessageHighlight(primary: primary)
        }
        self.scheduleMentionReadOnVisibleIfNeeded(
            for: request,
            positionedPrimary: primary
        )
        self.finishActiveAnchorExecution(token: self.activeAnchorExecutionState?.transactionToken)
    }

    private func initialAnchorExecutionState(
        for request: ChatOpenMessageRequest
    ) -> ChatAnchorExecutionState {
        ChatAnchorExecutionState(
            request: request,
            usesBootstrapLoading: self.shouldUseBootstrapLoading(for: request)
        )
    }

    @discardableResult
    private func ensureActiveAnchorExecutionState(
        for request: ChatOpenMessageRequest
    ) -> ChatAnchorExecutionState {
        if let state = self.activeAnchorExecutionState,
           state.request == request {
            if self.anchorTransactionGate.snapshot.activeToken != state.transactionToken {
                _ = self.anchorTransactionGate.begin(
                    token: state.transactionToken,
                    requestIdentity: self.anchorRequestIdentity(request)
                )
            }
            return state
        }

        let state = self.initialAnchorExecutionState(for: request)
        _ = self.anchorTransactionGate.begin(
            token: state.transactionToken,
            requestIdentity: self.anchorRequestIdentity(request)
        )
        self.activeAnchorExecutionState = state
        return state
    }

    private func anchorRequestIdentity(_ request: ChatOpenMessageRequest) -> String {
        [
            request.owner,
            request.chatJid,
            request.conversationType.rawValue,
            request.anchor.messagePrimary ?? "",
            request.anchor.archivedId ?? "",
            request.anchor.messageId ?? "",
            request.source.rawValue
        ].joined(separator: "|")
    }

    private func notifyAnchorPositioningStarted(token: ChatAnchorTransactionToken) {
        guard self.anchorTransactionGate.markPositioningStarted(token: token) else {
            return
        }
        self.activeAnchorExecutionHooks?.onPositioningStarted?()
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

    private func finishActiveAnchorExecution(token: ChatAnchorTransactionToken? = nil) {
        guard let executionState = self.activeAnchorExecutionState else {
            return
        }
        let effectiveToken = token ?? executionState.transactionToken
        guard executionState.transactionToken == effectiveToken,
              self.anchorTransactionGate.finish(token: effectiveToken) else {
            return
        }
        let onPositioned = self.activeAnchorExecutionHooks?.onPositioned
        self.cleanupAnchorExecutionResources(executionState)
        self.pendingOpenMessageRequest = nil
        self.activeAnchorExecutionState = nil
        self.activeAnchorExecutionHooks = nil
        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setSearchAnchorNavigationScrollLocked(false)
        self.setLoadingIndicatorVisible(false)
        self.setDatasourceLoadingEnabled(true)
        self.setSearchResultsPanelContextLoading(false)
        onPositioned?()
    }

    private func failActiveAnchorExecution(
        token: ChatAnchorTransactionToken? = nil,
        failure: ChatAnchorTransactionFailure = .targetMissing
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.failActiveAnchorExecution(token: token, failure: failure)
            }
            return
        }

        guard let executionState = self.activeAnchorExecutionState else {
            return
        }
        let effectiveToken = token ?? executionState.transactionToken
        guard executionState.transactionToken == effectiveToken,
              self.anchorTransactionGate.fail(token: effectiveToken, failure: failure) else {
            return
        }
        let onFailed = self.activeAnchorExecutionHooks?.onFailed
        self.cleanupAnchorExecutionResources(executionState)
        self.clearAnchorExecutionPresentationState()
        let usesBootstrapLoading = executionState.usesBootstrapLoading
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
            requestSource: executionState.request.source,
            usesBootstrapLoading: usesBootstrapLoading,
            hasFailureHook: hasFailureHook
        ) else { return }
        self.view.makeToast("Original message is no longer available")
    }

    internal func cancelActiveAnchorExecutionForLifecycle() {
        guard let executionState = self.activeAnchorExecutionState else {
            return
        }
        self.cancelActiveAnchorExecution(
            token: executionState.transactionToken,
            failure: .disappeared,
            invokeFailureHook: false
        )
    }

    private func cancelActiveAnchorExecution(
        token: ChatAnchorTransactionToken,
        failure: ChatAnchorTransactionFailure,
        invokeFailureHook: Bool
    ) {
        guard let executionState = self.activeAnchorExecutionState,
              executionState.transactionToken == token,
              self.anchorTransactionGate.cancel(token: token, failure: failure) else {
            return
        }
        let onFailed = invokeFailureHook ? self.activeAnchorExecutionHooks?.onFailed : nil
        self.cleanupAnchorExecutionResources(executionState)
        self.clearAnchorExecutionPresentationState()
        onFailed?()
    }

    private func cleanupAnchorExecutionResources(_ executionState: ChatAnchorExecutionState) {
        var queryIds = executionState.contextPrefetchQueryIds
        if let remoteQueryId = executionState.remoteQueryId {
            queryIds.insert(remoteQueryId)
        }
        queryIds.forEach { queryId in
            self.anchorTransactionTimeoutWorkItems.removeValue(forKey: queryId)?.cancel()
            self.anchorTransactionTokenByQueryId.removeValue(forKey: queryId)
            self.abortedRemoteHistoryQueryIds.insert(queryId)
            self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)
        }
    }

    private func clearAnchorExecutionPresentationState() {
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

        var state = self.ensureActiveAnchorExecutionState(for: request)
        let transactionToken = state.transactionToken
        state.lastAttemptedRemotePlan = plan
        state.remoteQueryId = queryId
        state.isRemoteFetchInFlight = true
        state.isWaitingForObserverSync = false
        state.isPositioning = false
        self.activeAnchorExecutionState = state
        guard self.anchorTransactionGate.acquire(.query(queryId), token: transactionToken) else {
            return nil
        }
        guard self.anchorTransactionGate.acquire(.loader, token: transactionToken),
              request.source != .search || self.anchorTransactionGate.acquire(
                .scrollLock,
                token: transactionToken
              ) else {
            return nil
        }
        self.anchorTransactionTokenByQueryId[queryId] = transactionToken
        self.scheduleAnchorTransactionTimeout(queryId: queryId, token: transactionToken)
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

        self.performArchiveAction(queryIds: [queryId], transactionToken: transactionToken, { stream, mam in
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
            self.failActiveAnchorExecution(token: transactionToken, failure: .disconnected)
        })

        return queryId
    }

    private func performArchiveAction(
        queryIds: Set<String> = [],
        transactionToken: ChatAnchorTransactionToken? = nil,
        _ action: @escaping (XMPPStream, MessageArchiveManager) -> Void,
        unavailable: (() -> Void)? = nil
    ) {
        if let transactionToken,
           self.anchorTransactionGate.snapshot.activeToken != transactionToken {
            return
        }
        queryIds.forEach {
            self.registerRemoteHistoryEndPageDispatcher(queryId: $0)
            self.registerRemoteHistoryFailureDispatcher(queryId: $0)
        }
        let fallback = {
            if let transactionToken,
               self.anchorTransactionGate.snapshot.activeToken != transactionToken {
                return
            }
            guard let account = AccountManager.shared.find(for: self.owner) else {
                queryIds.forEach {
                    self.unregisterRemoteHistoryEndPageDispatcher(queryId: $0)
                }
                unavailable?()
                return
            }

            account.action { user, stream in
                if let transactionToken,
                   self.anchorTransactionGate.snapshot.activeToken != transactionToken {
                    return
                }
                queryIds.forEach {
                    self.registerRemoteHistoryPersistenceSource(user.messages, queryId: $0)
                }
                action(stream, user.mam)
            }
        }

        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            if let transactionToken,
               self.anchorTransactionGate.snapshot.activeToken != transactionToken {
                return
            }
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

    private func scheduleAnchorTransactionTimeout(
        queryId: String,
        token: ChatAnchorTransactionToken
    ) {
        self.anchorTransactionTimeoutWorkItems.removeValue(forKey: queryId)?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.anchorTransactionTokenByQueryId[queryId] == token else {
                return
            }
            self.failActiveAnchorExecution(token: token, failure: .timeout)
        }
        self.anchorTransactionTimeoutWorkItems[queryId] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ChatInteractiveRemoteArchiveTimeoutPolicy.timeout,
            execute: workItem
        )
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
        self.timelineSession?.firstIncoming(afterArchiveBoundaryId: boundaryArchivedId)
            ?? self.timelineSession?.resolvedMessage(
                primary: nil,
                archivedId: boundaryArchivedId,
                messageId: nil
            )
    }

    private func unreadBoundaryFirstFrameLocalAnchor(
        for request: ChatOpenMessageRequest,
        residentSnapshot: ChatTimelineSessionSnapshot? = nil
    ) -> (message: MessageStorageItem, index: Int)? {
        guard request.source == .initialUnreadBoundary,
              case .firstIncomingAfterBoundary(let boundaryArchivedId) = request.targetResolution else {
            return nil
        }

        guard let timelineSession = self.timelineSession else { return nil }
        let snapshot = residentSnapshot ?? timelineSession.snapshot
        guard let message = timelineSession.firstIncoming(
            afterArchiveBoundaryId: boundaryArchivedId
        ) else {
            return nil
        }
        let index = snapshot.residentIndex.index(primary: message.primary) ?? 0
        return (message, index)
    }

    private func searchFirstFrameLocalAnchor(
        for request: ChatOpenMessageRequest,
        residentSnapshot: ChatTimelineSessionSnapshot? = nil
    ) -> (message: MessageStorageItem, index: Int)? {
        guard request.source == .search else {
            return nil
        }

        guard let timelineSession = self.timelineSession else { return nil }
        let snapshot = residentSnapshot ?? timelineSession.snapshot
        guard let message = self.sessionAnchorMessage(for: request)?.message else {
            return nil
        }
        let index = snapshot.residentIndex.index(primary: message.primary)
                ?? RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(message.archivedId)
                    .flatMap({ snapshot.residentIndex.index(archivedId: $0) })
                ?? snapshot.residentIndex.index(messageId: message.messageId)
                ?? 0
        return (message, index)
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
        self.sessionAnchorMessage(for: request)
    }

    private func sessionAnchorMessage(
        for request: ChatOpenMessageRequest
    ) -> (message: MessageStorageItem, matchSource: ChatAnchorLookupMatchSource)? {
        guard let timelineSession = self.timelineSession else { return nil }

        if case .firstIncomingAfterBoundary(let boundaryArchivedId) = request.targetResolution,
           let message = timelineSession.firstIncoming(afterArchiveBoundaryId: boundaryArchivedId)
                ?? timelineSession.resolvedMessage(primary: nil, archivedId: boundaryArchivedId, messageId: nil) {
            return (message, .unreadBoundaryAfter)
        }

        if request.source == .search {
            guard let message = timelineSession
                .resolvedSearchMessageResolution(anchor: request.anchor)
                .message else {
                return nil
            }
            let source: ChatAnchorLookupMatchSource
            if request.anchor.messagePrimary == message.primary {
                source = .primary
            } else if request.anchor.archivedId == message.archivedId {
                source = .archivedId
            } else if request.anchor.messageId == message.messageId {
                source = .messageId
            } else {
                source = .metadataFallback
            }
            return (message, source)
        }

        let anchor = request.anchor
        let orderedLookups: [(ChatAnchorLookupMatchSource, String?, String?, String?)] = [
            (.primary, anchor.messagePrimary, nil, nil),
            (.archivedId, nil, anchor.archivedId, nil),
            (.messageId, nil, nil, anchor.messageId)
        ]

        for (source, primary, archivedId, messageId) in orderedLookups {
            guard primary?.isNotEmpty == true || archivedId?.isNotEmpty == true || messageId?.isNotEmpty == true else {
                continue
            }
            if let message = timelineSession.resolvedMessage(
                primary: primary,
                archivedId: archivedId,
                messageId: messageId
            ) {
                return (message, source)
            }
        }

        return nil
    }

    private func typedAnchorResolutionFailure(
        for request: ChatOpenMessageRequest
    ) -> ChatAnchorTransactionFailure {
        guard request.source == .search,
              let timelineSession = self.timelineSession else {
            return .targetMissing
        }
        return timelineSession
            .resolvedSearchMessageResolution(anchor: request.anchor)
            .failure ?? .targetMissing
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
              let residentSnapshot = self.timelineSession?.snapshot,
              let localAnchorIndex = self.savedPositionFirstFrameObserverIndex(
                for: request,
                residentSnapshot: residentSnapshot
              ) else {
            return true
        }

        let archiveCoverageContext = self.savedPositionFirstFrameArchiveCoverageContext(
            localAnchorIndex: localAnchorIndex,
            residentSnapshot: residentSnapshot
        )
        guard archiveCoverageContext.knownGaps.isNotEmpty else {
            return true
        }

        if case .savedPosition = ChatSavedPositionFirstFramePolicy.decision(
            requestSource: request.source,
            isSynced: true,
            observerCount: residentSnapshot.items.count,
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
        self.savedPositionFirstFrameArchiveCoverageContext(
            localAnchorIndex: localAnchorIndex,
            residentSnapshot: self.timelineSession?.snapshot
        )
    }

    private func savedPositionFirstFrameArchiveCoverageContext(
        localAnchorIndex: Int?,
        residentSnapshot: ChatTimelineSessionSnapshot?
    ) -> (
        archivedIdsByIndex: [Int: String],
        knownGaps: [RegularChatArchiveGap]
    ) {
        guard self.conversationType == .regular,
              let residentSnapshot else {
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
            .replacementWindow(around: localAnchorIndex, totalCount: residentSnapshot.items.count)
        let sampledIndices = Set([
            window.minIndex,
            localAnchorIndex,
            max(window.minIndex, window.maxIndex - 1)
        ])

        var archivedIdsByIndex: [Int: String] = [:]
        for index in sampledIndices where residentSnapshot.items.indices.contains(index) {
            if let archiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                residentSnapshot.items[index].archivedId
            ) {
                archivedIdsByIndex[index] = archiveId
            }
        }

        return (archivedIdsByIndex, archiveState.knownGaps)
    }

    private func resolvedJumpTarget(
        primary: String? = nil,
        archivedId: String? = nil,
        messageId: String? = nil
    ) -> ResolvedJumpTarget? {
        guard let snapshot = self.timelineSession?.snapshot else { return nil }

        if let primary,
           let observerIndex = snapshot.residentIndex.index(primary: primary),
           snapshot.items.indices.contains(observerIndex) {
            let item = snapshot.items[observerIndex]
            return ResolvedJumpTarget(
                primary: item.primary,
                archivedId: item.archivedId.isNotEmpty ? item.archivedId : nil
            )
        }

        if let archivedId,
           archivedId.isNotEmpty,
           let observerIndex = snapshot.residentIndex.index(archivedId: archivedId),
           snapshot.items.indices.contains(observerIndex) {
            let item = snapshot.items[observerIndex]
            return ResolvedJumpTarget(
                primary: item.primary,
                archivedId: item.archivedId.isNotEmpty ? item.archivedId : nil
            )
        }

        if let messageId,
           messageId.isNotEmpty,
           let observerIndex = snapshot.residentIndex.index(messageId: messageId),
           snapshot.items.indices.contains(observerIndex) {
            let item = snapshot.items[observerIndex]
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
        guard let snapshot = self.timelineSession?.snapshot,
              let observerIndex = snapshot.residentIndex.index(primary: target.primary) else {
            self.chatScrollDirection = direction
            self.mapAndApplyTimelineAnchor(
                ChatTimelineAnchor(
                    primary: target.primary,
                    archivedId: target.archivedId,
                    messageId: nil,
                    date: nil
                ),
                mode: .fullReload(),
                animated: false,
                completion: { completion(target) },
                cancelledCompletion: { completion(target) }
            )
            return
        }

        let window = self.datasetCoordinator.replacementWindow(
            around: observerIndex,
            totalCount: snapshot.items.count
        )
        self.chatScrollDirection = direction
        self.timelineInteractionState.performLocked {
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
        completion: ((Bool) -> Void)? = nil
    ) {
        _ = preferredScrollDirection
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
            self.timelineInteractionState.unlock()
            completion?(false)
            return
        }
        let indexPath = IndexPath(row: 0, section: scrollIndex)
        guard let targetOffsetY = self.centeredContentOffsetY(for: indexPath) else {
            self.preventHidingDate = false
            self.setDatasourceLoadingEnabled(true)
            self.timelineInteractionState.unlock()
            completion?(false)
            return
        }

        let finalize = {
            let currentItem = self.datasourceItem(at: indexPath)
            let didPosition = ChatAnchorPositionVerificationPolicy.isPositioned(
                expectedPrimary: primary,
                expectedArchivedId: archivedId,
                actualPrimary: currentItem?.primary,
                actualArchivedId: currentItem?.archivedId,
                actualOffsetY: self.messagesCollectionView.contentOffset.y,
                targetOffsetY: targetOffsetY
            )
            if didPosition,
               let cell = self.messagesCollectionView.cellForItem(at: indexPath) as? MessageContentCell {
                cell.setSelected(state: highlight)
            }
            if didPosition {
                self.retainPositionedMessageAnchor(
                    primary: primary,
                    archivedId: archivedId,
                    indexPath: indexPath
                )
            }
            if self.inSearchMode.value || self.xabberInputView.state == .search {
                self.refreshVisibleSearchSelection()
            }
            self.preventHidingDate = false
            self.timelineInteractionState.unlock()
            self.setFloatingDateVisible(true)
            self.setFloatingDateHidden(true)
            self.setDatasourceLoadingEnabled(true)
            completion?(didPosition)
        }

        let targetOffset = CGPoint(
            x: self.messagesCollectionView.contentOffset.x,
            y: targetOffsetY
        )
        guard animated,
              abs(self.messagesCollectionView.contentOffset.y - targetOffsetY) > 0.5 else {
            self.messagesCollectionView.setContentOffset(targetOffset, animated: false)
            finalize()
            return
        }

        let animator = UIViewPropertyAnimator(duration: 0.25, curve: .easeInOut) {
            self.messagesCollectionView.setContentOffset(targetOffset, animated: false)
        }
        animator.addCompletion { _ in
            finalize()
        }
        animator.startAnimation()
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

    private func retainPositionedMessageAnchor(
        primary: String,
        archivedId: String?,
        indexPath: IndexPath
    ) {
        guard let item = self.datasourceItem(at: indexPath),
              let frame = self.messagesCollectionView.layoutAttributesForItem(at: indexPath)?.frame
                ?? self.messagesCollectionView.cellForItem(at: indexPath)?.frame else {
            self.retainedMessageAnchor = nil
            return
        }
        self.retainedMessageAnchor = ChatRetainedMessageAnchor(
            primary: primary,
            archivedId: archivedId ?? item.archivedId,
            displayRevision: self.anchorDisplayRevision(for: item),
            viewportRelativeMinY: frame.minY - self.messagesCollectionView.contentOffset.y
        )
    }

    internal func anchorDisplayRevision(for item: Datasource) -> String {
        [
            item.primary,
            item.archivedId ?? "",
            item.messageId,
            String(item.editDate?.timeIntervalSince1970 ?? 0),
            String(describing: item.kind)
        ].joined(separator: "|")
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
            self.anchorTransactionTimeoutWorkItems.removeValue(forKey: $0)?.cancel()
            self.anchorTransactionTokenByQueryId.removeValue(forKey: $0)
            self.unregisterRemoteHistoryPersistenceSource(queryId: $0)
        }
        state.contextPrefetchAnchorKey = anchorKey
        state.contextPrefetchQueryIds = []
        state.contextPrefetchPendingQueryIds = []
        state.contextPrefetchExpectedMessageCount = 0
        state.contextPrefetchPersistedMessageCount = 0
        state.didObserveContextPostIdleTick = false
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
                // A query leaves `contextPrefetchPendingQueryIds` only from the
                // post-persistence-barrier final callback.
                areMessagePipelinesIdle: executionState.contextPrefetchPendingQueryIds.isEmpty,
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

        guard let residentSnapshot = self.timelineSession?.snapshot,
              let observerIndex = residentSnapshot.residentIndex.index(primary: target.primary) else {
            self.syncAnchorExecutionFlags()
            return false
        }

        let effectiveArchivedId = request.anchor.archivedId ?? target.archivedId
        let coverage = effectiveArchivedId.map {
            ChatAnchorContextPrefetchPolicy.coverage(
                observerIndex: observerIndex,
                totalCount: residentSnapshot.items.count,
                targetArchivedId: $0,
                archiveState: self.loadChatArchiveStateSnapshot()
            )
        }
        let plan = ChatAnchorContextPrefetchPolicy.plan(
            coverage: coverage ?? ChatAnchorContextCoverage(
                olderLocalCount: observerIndex,
                newerLocalCount: max(0, residentSnapshot.items.count - observerIndex - 1),
                olderBoundary: .unknown,
                newerBoundary: .unknown
            ),
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
        let transactionToken = executionState.transactionToken
        guard queryIds.allSatisfy({ queryId in
            self.anchorTransactionGate.acquire(.query(queryId), token: transactionToken)
        }) else {
            return false
        }
        guard self.anchorTransactionGate.acquire(.loader, token: transactionToken),
              request.source != .search || self.anchorTransactionGate.acquire(
                .scrollLock,
                token: transactionToken
              ) else {
            return false
        }
        queryIds.forEach { queryId in
            self.anchorTransactionTokenByQueryId[queryId] = transactionToken
            self.scheduleAnchorTransactionTimeout(queryId: queryId, token: transactionToken)
        }

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
        self.performArchiveAction(queryIds: queryIds, transactionToken: transactionToken, { stream, mam in
            if let newerPageSize = plan.newerPageSize,
               let newerQueryId {
                _ = mam.requestNewerHistoryPage(
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
                _ = mam.requestOlderHistoryPage(
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
                  state.transactionToken == transactionToken,
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
        guard let residentSnapshot = self.timelineSession?.snapshot,
              let observerIndex = residentSnapshot.residentIndex.index(primary: target.primary) else {
            return
        }

        let effectiveArchivedId = request.anchor.archivedId ?? target.archivedId
        let coverage = effectiveArchivedId.map {
            ChatAnchorContextPrefetchPolicy.coverage(
                observerIndex: observerIndex,
                totalCount: residentSnapshot.items.count,
                targetArchivedId: $0,
                archiveState: self.loadChatArchiveStateSnapshot()
            )
        }
        let plan = ChatAnchorContextPrefetchPolicy.plan(
            coverage: coverage ?? ChatAnchorContextCoverage(
                olderLocalCount: observerIndex,
                newerLocalCount: max(0, residentSnapshot.items.count - observerIndex - 1),
                olderBoundary: .unknown,
                newerBoundary: .unknown
            ),
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
                _ = mam.requestNewerHistoryPage(
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
                _ = mam.requestOlderHistoryPage(
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

        var executionState = self.ensureActiveAnchorExecutionState(for: request)
        let transactionToken = executionState.transactionToken

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
            let direction = self.activeAnchorExecutionHooks?.direction ?? .up
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
                centerTargetInViewport: true,
                shouldApply: {
                    self.anchorTransactionGate.accept(
                        .mapping,
                        token: transactionToken
                    ) == .accepted
                },
                transactionCompletion: { result in
                    guard self.anchorTransactionGate.accept(
                        .apply,
                        token: transactionToken
                    ) == .accepted else {
                        return
                    }

                    guard case .committed(let diagnostics) = result,
                          diagnostics.programmaticOffsetMutationCount <= 1,
                          diagnostics.nextRunLoopCorrectionCount == 0,
                          (diagnostics.anchorError ?? 0) <= 1,
                          let section = self.datasourceSnapshot.primaryIndex[positionTarget.primary],
                          self.datasource.indices.contains(section),
                          self.datasource[section].archivedId == positionTarget.archivedId || positionTarget.archivedId == nil,
                          self.anchorTransactionGate.accept(
                            .scroll,
                            token: transactionToken
                          ) == .accepted else {
                        self.failActiveAnchorExecution(
                            token: transactionToken,
                            failure: .targetDeleted
                        )
                        return
                    }

                    let usesTransientHighlight = request.source.usesTransientHighlight && request.highlight
                    let indexPath = IndexPath(item: 0, section: section)
                    self.retainPositionedMessageAnchor(
                        primary: positionTarget.primary,
                        archivedId: positionTarget.archivedId,
                        indexPath: indexPath
                    )
                    if usesTransientHighlight {
                        self.applyTransientMessageHighlight(primary: positionTarget.primary)
                    } else if request.highlight,
                              let cell = self.messagesCollectionView.cellForItem(at: indexPath) as? MessageContentCell {
                        cell.setSelected(state: true)
                    }
                    self.scheduleMentionReadOnVisibleIfNeeded(
                        for: request,
                        positionedPrimary: positionTarget.primary
                    )
                    self.finishActiveAnchorExecution(token: transactionToken)
                    if contextPrefetchMode == .background {
                        self.startBackgroundContextPrefetchIfNeeded(
                            around: positionTarget,
                            request: request
                        )
                    }
                },
                completion: nil,
                cancelledCompletion: {
                self.failActiveAnchorExecution(token: transactionToken)
            })
            self.notifyAnchorPositioningStarted(token: transactionToken)
        case .startRemoteFetch(let plan):
            _ = self.startRemoteAnchorFetch(plan: plan, for: request)
        case .waitForObserverSync, .none:
            self.syncAnchorExecutionFlags()
            return
        case .fail:
            self.failActiveAnchorExecution(
                token: transactionToken,
                failure: self.typedAnchorResolutionFailure(for: request)
            )
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
              self.timelineSession != nil else {
            return
        }

        _ = self.ensureActiveAnchorExecutionState(for: request)
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
            guard let snapshot = self.timelineSession?.snapshot,
                  let index = snapshot.residentIndex.index(archivedId: archivedId) else {
                notFound?()
                return
            }
            let window = self.datasetCoordinator.replacementWindow(
                around: index,
                totalCount: snapshot.items.count
            )
            self.timelineInteractionState.performLocked {
                self.syncCurrentPage(with: window)
                callback(self.sliceForWindow(window), index - window.minIndex)
                self.timelineInteractionState.unlock()
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
        if self.timelineSession?.snapshot.residentIndex.index(archivedId: archivedId) != nil {
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

        let revision = self.anchorDisplayRevision(for: self.datasource[section])
        ChatAnchorHighlightOverlay.install(
            on: cell,
            primary: primary,
            revision: revision
        )
        guard let overlay = cell.contentView.subviews.last,
              ChatAnchorHighlightOverlay.representedPrimary(in: cell) == primary,
              ChatAnchorHighlightOverlay.representedRevision(in: cell) == revision else {
            return
        }

        UIView.animate(
            withDuration: 0.25,
            delay: 0.55,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: {
                overlay.alpha = 0
            },
            completion: { _ in
                if ChatAnchorHighlightOverlay.representedPrimary(in: cell) == primary,
                   ChatAnchorHighlightOverlay.representedRevision(in: cell) == revision {
                    ChatAnchorHighlightOverlay.remove(from: cell)
                }
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
        let residentIndex = self.timelineSession?.snapshot.residentIndex
        let direction: ChatDirection = (target.observerIndex ?? Int.max) < (self.visibleRealMessagePrimaries().compactMap {
            residentIndex?.index(primary: $0)
        }.min() ?? Int.max)
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

        guard self.timelineInteractionState.isUnlocked else {
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
                ("currentPageLocked", self.timelineInteractionState.locked)
            ])
            if let transactionToken = self.anchorTransactionTokenByQueryId[queryId] {
                guard self.anchorTransactionGate.accept(
                    .remoteFinal(queryId: queryId),
                    token: transactionToken
                ) == .accepted else {
                    return
                }
                self.anchorTransactionTimeoutWorkItems.removeValue(forKey: queryId)?.cancel()
            }
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

            let finalPage = ChatRemoteHistoryFinalPage(
                state: state,
                first: first,
                last: last,
                count: count
            )
            if let context = self.interactiveHistoryPageLoadContext,
               context.queryId == queryId {
                self.cancelInteractiveRemoteArchiveTimeout(queryId: queryId)
                let disposition = self.remoteHistoryQueryCoordinator.receiveFinal(
                    queryId: queryId,
                    generation: context.generation,
                    page: finalPage
                ) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let committedPage):
                        guard committedPage.descriptor.conversationKey == self.chatTimelineConversationKey,
                              self.interactiveHistoryPageLoadContext?.queryId == queryId,
                              self.interactiveHistoryPageLoadContext?.generation == committedPage.descriptor.generation else {
                            return
                        }
                        self.handleCommittedRemoteHistoryFinal(
                            queryId: queryId,
                            originalState: state,
                            first: first,
                            last: last,
                            count: count,
                            completion: committedPage.persistence,
                            barrierDurationMs: ChatArchiveDebugTrace.milliseconds(since: enqueuedAt)
                        )
                    case .failure(let error):
                        self.handleInteractiveRemoteArchiveFailure(
                            queryId: queryId,
                            reason: .serverError,
                            streamKind: .unknown,
                            errorDescription: error.localizedDescription
                        )
                    }
                }
                switch disposition {
                case .accepted:
                    _ = self.markRemoteHistoryEndPageCompletionIfNeeded(queryId: queryId)
                    return
                case .duplicate:
                    ChatArchiveDebugTrace.log("remoteHistoryFinalDuplicate")
                    return
                case .stale:
                    ChatArchiveDebugTrace.log("remoteHistoryFinalStale", [
                        ("generation", context.generation)
                    ])
                    return
                case .unknown:
                    break
                }
            }

            switch self.remoteHistoryQueryCoordinator.classifyUnhandledFinal(queryId: queryId) {
            case .duplicate:
                self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)
                ChatArchiveDebugTrace.log("remoteHistoryFinalDuplicateWithoutContext")
                return
            case .stale:
                self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)
                ChatArchiveDebugTrace.log("remoteHistoryFinalStaleWithoutContext")
                return
            case .accepted, .unknown:
                break
            }

            let shouldDedupeCompletion = self.remoteHistoryEndPageDispatcherTokens[queryId] != nil ||
                self.completedRemoteHistoryEndPageQueryIds.contains(queryId)
            if shouldDedupeCompletion {
                guard self.markRemoteHistoryEndPageCompletionIfNeeded(queryId: queryId) else {
                    ChatArchiveDebugTrace.log("remoteHistoryFinalDuplicate")
                    return
                }
            }
            let requestConversationKey = self.chatTimelineConversationKey
            let barrierStartedAt = Date()
            ChatRemoteHistoryCompletionCoordinator.flushQueryMessagesAsync(
                owner: self.owner,
                queryId: queryId,
                state: state,
                conversationJid: self.jid,
                conversationType: self.conversationType
            ) { [weak self] completion in
                DispatchQueue.main.async {
                    guard let self,
                          self.chatTimelineConversationKey == requestConversationKey else {
                        return
                    }
                    self.handleCommittedRemoteHistoryFinal(
                        queryId: queryId,
                        originalState: state,
                        first: first,
                        last: last,
                        count: count,
                        completion: completion,
                        barrierDurationMs: ChatArchiveDebugTrace.milliseconds(since: barrierStartedAt)
                    )
                }
            }
        }
    }

    private func handleCommittedRemoteHistoryFinal(
        queryId: String,
        originalState: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int,
        completion: ChatRemoteHistoryCompletionResult,
        barrierDurationMs: Int
    ) {
        if let transactionToken = self.anchorTransactionTokenByQueryId[queryId] {
            guard self.anchorTransactionGate.accept(
                .persistence(queryId: queryId),
                token: transactionToken
            ) == .accepted else {
                return
            }
        }
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
            ("flushMs", barrierDurationMs),
            ("flushed", completion.flushedMessageCount),
            ("effectivePersisted", effectiveState.persistedMessageCount),
            ("visibleRows", visibleRows),
            ("residentCount", self.virtualTimelineState.residentPrimaryKeys.count),
            ("datasourceCount", self.datasource.count),
            ("activeRemoteLoad", self.virtualTimelineState.activeRemoteLoad?.queryId ?? "-")
        ])
        if self.handleInitialBootstrapEndPageIfNeeded(
            queryId: queryId,
            state: effectiveState,
            count: count,
            persistedMessageCount: effectiveState.persistedMessageCount,
            persistedRowsForQuery: completion.persistenceSummary.persistedRows,
            visibleRowsForConversation: visibleRows
        ) {
            ChatArchiveDebugTrace.log("chatDidReceiveEndPageHandled", [("queryId", queryId), ("handler", "initialBootstrap")])
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
            ChatArchiveDebugTrace.log("chatDidReceiveEndPageHandled", [("queryId", queryId), ("handler", "interactivePaging")])
            return
        }
        if self.handleAnchorContextPrefetchEndPageIfNeeded(queryId: queryId, state: effectiveState, count: count) {
            ChatArchiveDebugTrace.log("chatDidReceiveEndPageHandled", [("queryId", queryId), ("handler", "anchorContextPrefetch")])
            return
        }
        if self.handleAnchorRemoteFetchEndPageIfNeeded(queryId: queryId, state: effectiveState, count: count) {
            ChatArchiveDebugTrace.log("chatDidReceiveEndPageHandled", [("queryId", queryId), ("handler", "anchorRemoteFetch")])
            return
        }
        if self.finishInChatSearchQueryIfCurrent(queryId: queryId, emptyList: first == last) {
            ChatArchiveDebugTrace.log("chatDidReceiveEndPageHandled", [("queryId", queryId), ("handler", "search")])
            return
        }
        ChatArchiveDebugTrace.log("chatDidReceiveEndPageUnhandled", [
            ("queryId", queryId),
            ("count", count),
            ("effectivePersisted", effectiveState.persistedMessageCount)
        ])
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

        self.anchorTransactionTokenByQueryId.removeValue(forKey: queryId)
        self.anchorTransactionTimeoutWorkItems.removeValue(forKey: queryId)?.cancel()
        self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)

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

        self.anchorTransactionTokenByQueryId.removeValue(forKey: queryId)
        self.anchorTransactionTimeoutWorkItems.removeValue(forKey: queryId)?.cancel()
        self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)

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
                self.failActiveAnchorExecution(failure: .targetMissing)
            }
        case .fail:
            let failure = self.pendingOpenMessageRequest
                .map { self.typedAnchorResolutionFailure(for: $0) } ?? .targetMissing
            self.failActiveAnchorExecution(failure: failure)
        case .none:
            self.syncAnchorExecutionFlags()
        }

        return true
    }

    @discardableResult
    internal func handleAnchorRemoteFailureIfNeeded(
        queryId: String,
        reason: MessageArchiveRequestFailureReason
    ) -> Bool {
        guard let transactionToken = self.anchorTransactionTokenByQueryId[queryId],
              self.anchorTransactionGate.accept(
                .remoteFailure(queryId: queryId),
                token: transactionToken
              ) == .accepted else {
            return false
        }

        let failure: ChatAnchorTransactionFailure
        switch reason {
        case .timeout:
            failure = .timeout
        case .uiActionDisconnect, .requestStartFailed:
            failure = .disconnected
        case .serverError:
            failure = .iqError
        }
        self.failActiveAnchorExecution(token: transactionToken, failure: failure)
        return true
    }
}
