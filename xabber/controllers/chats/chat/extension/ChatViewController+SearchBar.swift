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

/// UI-only token that keeps calendar dismissal and the archive-engine
/// timestamp intent in the same search generation.
struct ChatSearchCalendarDateRequest: Equatable, Sendable {
    let id: UUID
    let generation: UInt64
    let scope: ChatSearchResult.Scope
    let selectedTimestamp: Date
}

enum ChatAnchorLookupMatchSource: String, Equatable {
    case primary = "primary"
    case archivedId = "archived-id"
    case messageId = "message-id"
    case unreadBoundaryAfter = "unread-boundary-after"
    case metadataFallback = "metadata-fallback"
}

enum ChatInitialScrollPolicy {
    static func shouldDeferDefaultScroll(
        hasPendingAnchorRequest: Bool,
        isAnchorNavigationInFlight: Bool
    ) -> Bool {
        hasPendingAnchorRequest || isAnchorNavigationInFlight
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
        if source == .mentionNotification ||
            source == .pushNotification ||
            source == .search ||
            source == .initialUnreadBoundary ||
            source == .savedVisiblePosition ||
            source == .external ||
            source == .directOpenAtMessage ||
            source == .pinnedMessage ||
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

enum ChatAnchorFailureRecoveryPolicy {
    static func shouldRunDefaultFailurePresentation(
        requestSource: ChatOpenMessageRequestSource?,
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

        return !hasFailureHook
    }
}

struct ChatAnchorExecutionState: Equatable {
    let request: ChatOpenMessageRequest
    let transactionToken: ChatAnchorTransactionToken
    var isPositioning: Bool = false

    init(
        request: ChatOpenMessageRequest,
        transactionToken: ChatAnchorTransactionToken = ChatAnchorTransactionToken()
    ) {
        self.request = request
        self.transactionToken = transactionToken
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

enum ChatProofScopedOpenTargetRoute: Equatable {
    case local(ArchiveCursor)
    case remote
}

enum ChatProofScopedOpenTargetAdmission {
    static func route(
        request: ChatOpenMessageRequest,
        verifiedScope: ChatTimelineVerifiedScope?
    ) -> ChatProofScopedOpenTargetRoute {
        guard let verifiedScope,
              request.owner == verifiedScope.conversationKey.owner,
              request.chatJid == verifiedScope.conversationKey.jid,
              request.conversationType ==
                verifiedScope.conversationKey.conversationType,
              let rawArchiveID = request.anchor.archivedId,
              let cursor = ArchiveCursor(rawValue: rawArchiveID),
              verifiedScope.contains(cursor) else {
            return .remote
        }
        return .local(cursor)
    }
}

struct ChatProofScopedLocalTargetRequestContext: Equatable {
    let id: UUID
    let request: ChatOpenMessageRequest
    let transactionToken: ChatAnchorTransactionToken
    let archiveCursor: ArchiveCursor
    let scope: ChatTimelineVerifiedScope
    let baseGeneration: UInt64
    let applyGeneration: UInt64
    let searchGeneration: Int?
    let attempt: Int
}

private final class ChatProofScopedLocalTargetCommitReceipt {
    var snapshot: ChatTimelineSessionSnapshot?
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

        if let sourceDate = anchor.sourceDate {
            let dated = anchorableItems.filter { $0.element.sentDate != .distantPast }
            if let nearestAfter = dated
                .filter({ $0.element.sentDate >= sourceDate })
                .min(by: { $0.element.sentDate < $1.element.sentDate }) {
                return nearestAfter.offset
            }
            return dated
                .filter { $0.element.sentDate < sourceDate }
                .max(by: { $0.element.sentDate < $1.element.sentDate })?
                .offset
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

enum ChatSearchLifecycleTeardownReason: Equatable {
    case navigationAway
    case scopeChanged
    case deinitializing
}

extension ChatViewController {
    internal func teardownChatSearchLifecycle(
        reason: ChatSearchLifecycleTeardownReason
    ) {
        assert(Thread.isMainThread, "Chat search teardown must run on the main thread")

        searchSessionDebounceWorkItem?.cancel()
        searchSessionDebounceWorkItem = nil
        searchSessionDebounceGeneration = nil
        applySearchSessionEffects(searchSession.cancel())

        if let account = AccountManager.shared.find(for: owner) {
            let queryID = currentSearchQueryId
            let conversation = archiveEngineConversationKey
            Task {
                await account.archiveEngine.cancelSearch(
                    conversation: conversation,
                    clientQueryID: queryID
                )
            }
        }
        searchSessionGenerationByQueryId.removeAll()
        _ = searchLocalProvider.cancelAll()

        pendingSearchCalendarDateRequest = nil
        isChatSearchCalendarDateResolutionLoading = false

        searchCalendarViewController?.onCancel = nil
        searchCalendarViewController?.onComplete = nil
        searchCalendarViewController?.onAccessibilityFocusRequest = nil
        removeChatSearchCalendarControllerImmediately()
        cleanupSearchAnimationsForLifecycle()
        searchChromeTransitionCoordinator.cleanupAnimations(finalState: .hidden)
        searchModeTransitionCoordinator.cleanupAnimations(finalState: .chat)
        searchNavigationFeedbackCoordinator.cancel()

        let hadPresentationState = searchPresentationState.isActive ||
            searchPresentationState.positioningPhase != .idle ||
            searchPresentationState.query.isNotEmpty
        if hadPresentationState {
            reduceSearchPresentationState(.cancelSearch)
        }
        clearInChatSearchQuery(clearResults: true, panelState: .idle)
        removeChatSearchResultsListController()
        searchOlderPageNavigationGate.reset(generation: searchSession.generation)
        searchResultNavigationState = .idle
        pendingOpenMessageRequest = nil
        pendingSearchActivationRequest = nil
        searchMessagesQueue.removeAll()
        searchResultPresentations.removeAll()
        searchTextObserver.accept(nil)
        inSearchMode.accept(false)
        searchBar.text = nil
        chatSearchCalendarDateAnnouncementHandler = nil
        chatSearchCalendarDateErrorHandler = nil
        chatSearchAccessibilityAnnouncementHandler = nil
        chatSearchAccessibilityAnnouncementState = .init()

        if isViewLoaded {
            searchInputBar.text = nil
            searchInputBar.endEditing(true)
            searchBar.endEditing(true)
            hideSearchInputOverlay()
            xabberInputView.changeState(to: .normal)
            navigationItem.setHidesBackButton(false, animated: false)
            setChatSearchTimelineHidden(false)
            refreshChatSearchAccessibilityOrder()
        }

        if reason == .navigationAway || reason == .deinitializing {
            removeObservers()
        }
    }

    internal func handleChatSearchApplicationDidEnterBackground() {
        assert(Thread.isMainThread, "Chat search background handling must run on the main thread")
        let interruptedPhase = searchPresentationState.resultPhase
        let interruptedPositioning = searchPresentationState.positioningPhase
        applySearchSessionEffects(searchSession.interruptForLifecycle())

        if interruptedPhase == .debouncing || interruptedPhase == .searching {
            reduceSearchPresentationState(
                .failed(generation: searchPresentationState.generation)
            )
        }
        if interruptedPositioning != .idle {
            reduceSearchPresentationState(
                .navigationFinished(generation: searchPresentationState.generation)
            )
        }
        searchCalendarViewController?.settleTransitionForLifecycleInterruption()
        cleanupSearchAnimationsForLifecycle()
        _ = cancelChatSearchCalendarDateResolution()
    }

    internal func handleChatSearchApplicationWillEnterForeground() {
        assert(Thread.isMainThread, "Chat search foreground handling must run on the main thread")
        guard !invalidateChatSearchForCurrentScopeIfNeeded() else { return }
        searchCalendarViewController?.settleTransitionForLifecycleInterruption()
        cleanupSearchAnimationsForLifecycle()
        if isViewLoaded {
            renderSearchResultSurfaceFromPresentation(animated: false)
            renderSearchNavigationButtons(animated: false)
            refreshChatSearchAccessibilityOrder()
        }
    }

    internal func handleChatSearchLayoutInterruption() {
        assert(Thread.isMainThread, "Chat search layout interruption must run on the main thread")
        searchCalendarViewController?.settleTransitionForLifecycleInterruption()
        cleanupSearchAnimationsForLifecycle()
        guard isViewLoaded else { return }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        renderSearchResultSurfaceFromPresentation(animated: false)
        bringSearchModeChromeToFront()
    }

    internal func handleChatSearchMemoryWarning() {
        ChatSearchHighlighter.removeCachedResults()
        ChatSearchFormatterCache.shared.removeAll()
        searchResultsListViewController?.handleMemoryWarning()
    }

    @discardableResult
    internal func invalidateChatSearchForCurrentScopeIfNeeded() -> Bool {
        let scope = currentSearchSessionScope
        let sessionMismatch = searchSession.activeScope.map { $0 != scope } ?? false
        let resultMismatch = searchResultPresentations.contains { result in
            result.scope.owner != scope.owner ||
                result.scope.jid != scope.jid ||
                result.scope.conversationTypeRawValue != scope.conversationTypeRawValue
        }
        guard sessionMismatch || resultMismatch else { return false }
        teardownChatSearchLifecycle(reason: .scopeChanged)
        return true
    }

    internal func transitionSearchChrome(
        to finalState: ChatSearchChromeTransitionPlan.FinalState,
        animated: Bool,
        completion: ((ChatSearchChromeTransitionPlan.FinalState) -> Void)? = nil
    ) {
        assert(Thread.isMainThread, "Chat search chrome transitions must run on the main thread")
        guard isViewLoaded else {
            searchChromeTransitionCoordinator.cleanupAnimations(finalState: finalState)
            completion?(finalState)
            return
        }
        let generation = searchPresentationState.generation
        let hosts = [
            searchNavigationView.surfaceView,
            searchNavigationView.cancelButton,
            xabberInputView.searchPanel.leadingSurfaceView,
            xabberInputView.searchPanel.trailingSurfaceView
        ]
        searchChromeTransitionCoordinator.transition(
            to: finalState,
            generation: generation,
            animated: animated,
            animationSpec: searchAnimationSpec,
            contentHosts: hosts,
            isGenerationCurrent: { [weak self] candidateGeneration in
                guard let self,
                      self.searchPresentationState.generation == candidateGeneration else {
                    return false
                }
                switch finalState {
                case .visible:
                    return self.searchPresentationState.isActive
                case .hidden:
                    return !self.searchPresentationState.isActive
                }
            },
            completion: { finalState in
                completion?(finalState)
            }
        )
    }

    internal func cleanupSearchAnimationsForLifecycle() {
        assert(Thread.isMainThread, "Chat search lifecycle cleanup must run on the main thread")
        let chromeState: ChatSearchChromeTransitionPlan.FinalState =
            searchPresentationState.isActive ? .visible : .hidden
        searchChromeTransitionCoordinator.cleanupAnimations(finalState: chromeState)

        let listIsReducerFinal: Bool
        switch searchPresentationState.surfaceMode {
        case .list:
            listIsReducerFinal = true
        case .calendar:
            listIsReducerFinal = searchPresentationState.calendarOrigin == .list
        case .chat:
            listIsReducerFinal = false
        }
        searchModeTransitionCoordinator.cleanupAnimations(
            finalState: listIsReducerFinal ? .list : .chat
        )
        if isViewLoaded {
            searchNavigationButtonsView.cleanupAnimations(
                finalState: ChatSearchNavigationButtonsRenderPolicy.state(
                    presentation: searchPresentationState,
                    navigationBusy: searchResultNavigationState.isBusy ||
                        searchOlderPageNavigationGate.hasPendingNavigation,
                    canRequestOlderPage: searchOlderPageNavigationGate.canRequest
                )
            )
        }
        searchNavigationFeedbackCoordinator.cancel(
            generation: searchPresentationState.generation
        )
    }

    @discardableResult
    internal func reduceSearchPresentationState(
        _ event: ChatSearchPresentationState.Event
    ) -> ChatSearchPresentationState {
        assert(Thread.isMainThread, "Chat search presentation events must be reduced on the main thread")
        let previousSurfaceMode = searchPresentationState.surfaceMode
        searchPresentationState.reduce(event)
        if previousSurfaceMode == .calendar,
           searchPresentationState.surfaceMode != .calendar,
           searchCalendarViewController != nil {
            removeChatSearchCalendarControllerImmediately()
        }
        if isViewLoaded {
            searchNavigationView.render(
                .init(
                    query: searchPresentationState.draftQuery,
                    isRemoteSearching: searchPresentationState.resultPhase == .searching
                )
            )
            applySearchPanelStateFromPresentation()
            renderSearchResultSurfaceFromPresentation(
                animated: shouldAnimateSearchModeTransition(
                    for: event,
                    previousSurfaceMode: previousSurfaceMode
                )
            )
            renderSearchNavigationButtons(
                animated: shouldAnimateSearchNavigationButtons(for: event)
            )
            refreshChatSearchAccessibilityOrder()
        }
        return searchPresentationState
    }

    private func shouldAnimateSearchModeTransition(
        for event: ChatSearchPresentationState.Event,
        previousSurfaceMode: ChatSearchPresentationState.SurfaceMode
    ) -> Bool {
        guard previousSurfaceMode != searchPresentationState.surfaceMode else {
            return false
        }
        switch event {
        case .openList, .closeList:
            return true
        default:
            return false
        }
    }

    private func shouldAnimateSearchNavigationButtons(
        for event: ChatSearchPresentationState.Event
    ) -> Bool {
        switch event {
        case .openList, .closeList:
            return false
        default:
            return true
        }
    }

    internal func renderSearchResultSurfaceFromPresentation(animated: Bool = false) {
        assert(Thread.isMainThread, "Chat search surfaces must render on the main thread")
        guard isViewLoaded else {
            return
        }

        guard searchPresentationState.isActive else {
            searchModeTransitionCoordinator.reset(to: .chat)
            removeChatSearchResultsListController()
            setChatSearchTimelineHidden(false)
            return
        }

        let presentsListUnderCurrentSurface = searchPresentationState.surfaceMode == .list ||
            (searchPresentationState.surfaceMode == .calendar &&
                searchPresentationState.calendarOrigin == .list)
        guard presentsListUnderCurrentSurface,
              let model = makeChatSearchResultsListRenderModel(),
              model.canPresent else {
            guard let listController = searchResultsListViewController else {
                searchModeTransitionCoordinator.reset(to: .chat)
                setChatSearchTimelineHidden(false)
                return
            }
            if searchModeTransitionCoordinator.requestedMode != .chat ||
                !listController.view.isHidden {
                listController.retainVisibleAnchorForModeSwitch()
                transitionSearchResultSurface(
                    to: .chat,
                    animated: animated,
                    listController: listController
                )
            } else {
                setChatSearchTimelineHidden(false)
            }
            return
        }

        let listController: ChatSearchResultsListViewController
        if let current = searchResultsListViewController {
            listController = current
        } else {
            listController = ChatSearchResultsListViewController()
        }
        listController.render(model, animated: false)
        listController.onSelectResult = { [weak self] id in
            self?.handleChatSearchListResultSelection(
                id,
                generation: model.generation
            )
        }
        installChatSearchResultsListController(listController)
        if searchModeTransitionCoordinator.requestedMode != .list ||
            listController.view.isHidden {
            listController.prepareForModeSwitchToList(selectedID: model.selectedID)
        }
        transitionSearchResultSurface(
            to: .list,
            animated: animated,
            listController: listController
        )
    }

    private func transitionSearchResultSurface(
        to mode: ChatSearchModeTransitionPlan.Mode,
        animated: Bool,
        listController: ChatSearchResultsListViewController
    ) {
        let generation = searchPresentationState.generation
        searchModeTransitionCoordinator.transition(
            to: mode,
            generation: generation,
            animated: animated,
            animationSpec: searchAnimationSpec,
            containerView: view,
            listContentView: listController.view,
            timelineView: messagesCollectionView,
            isGenerationCurrent: { [weak self] candidateGeneration in
                guard let self else { return false }
                return self.searchPresentationState.isActive &&
                    self.searchPresentationState.generation == candidateGeneration
            },
            bringChromeToFront: { [weak self] in
                self?.bringSearchModeChromeToFront()
            },
            applyFinalMode: { [weak self, weak listController] finalMode in
                guard let self,
                      let listController,
                      self.searchPresentationState.generation == generation else {
                    return
                }
                switch finalMode {
                case .chat:
                    listController.view.isHidden = true
                    listController.view.isUserInteractionEnabled = false
                    self.setChatSearchTimelineHidden(false)
                case .list:
                    listController.view.isHidden = false
                    listController.view.isUserInteractionEnabled = true
                    self.setChatSearchTimelineHidden(true)
                }
                self.bringSearchModeChromeToFront()
                self.refreshChatSearchAccessibilityOrder()
            }
        )
    }

    private func bringSearchModeChromeToFront() {
        view.bringSubviewToFront(xabberInputView)
        view.bringSubviewToFront(searchNavigationButtonsView)
        bringSearchInputOverlayToFront()
    }

    internal func makeChatSearchResultsListRenderModel() -> ChatSearchResultsListRenderModel? {
        guard !invalidateChatSearchForCurrentScopeIfNeeded() else {
            return nil
        }
        guard searchPresentationState.isActive,
              searchPresentationState.resultPhase == .results,
              searchResultPresentations.isNotEmpty,
              let committedIndex = searchPresentationState.committedResultIndex,
              searchResultPresentations.indices.contains(committedIndex) else {
            return nil
        }

        let phase: ChatSearchResultsListRenderModel.Phase =
            searchOlderPageNavigationGate.hasPendingNavigation || searchSession.isProviderSearching
                ? .loadingNextPage
                : .populated
        return ChatSearchResultsListRenderModel(
            generation: UInt64(max(0, searchPresentationState.generation)),
            results: searchResultPresentations,
            selectedID: searchResultPresentations[committedIndex].id,
            phase: phase
        )
    }

    internal func handleChatSearchListResultSelection(
        _ id: ChatSearchResult.ID,
        generation: UInt64
    ) {
        assert(Thread.isMainThread, "Chat search list selection must run on the main thread")
        guard searchPresentationState.isActive,
              searchPresentationState.resultPhase == .results,
              generation == UInt64(max(0, searchPresentationState.generation)),
              let targetIndex = searchResultPresentations.firstIndex(where: { $0.id == id }),
              searchMessagesQueue.indices.contains(targetIndex),
              searchResultIdentity(for: searchMessagesQueue[targetIndex]) == id,
              makeSearchResultOpenMessageRequest(at: targetIndex) != nil else {
            return
        }

        let baseIndex = currentSearchResultNavigationBaseIndex()
            ?? searchPresentationState.committedResultIndex
            ?? targetIndex
        let direction: ChatDirection
        if targetIndex > baseIndex {
            direction = .up
        } else if targetIndex < baseIndex {
            direction = .down
        } else {
            direction = chatScrollDirection ?? .up
        }

        if searchPresentationState.surfaceMode == .list {
            reduceSearchPresentationState(.closeList)
        }
        searchResultsListViewController?.retainModeSwitchScrollAnchor(for: id)

        if timelineInteractionState.locked || searchResultNavigationState.isBusy {
            recordPendingSearchResultNavigation(
                index: targetIndex,
                scrollDirection: direction
            )
            return
        }

        openSearchResult(at: targetIndex, direction: direction)
    }

    internal func makeSearchResultOpenMessageRequest(at index: Int) -> ChatOpenMessageRequest? {
        guard searchMessagesQueue.indices.contains(index) else {
            return nil
        }
        let legacyItem = searchMessagesQueue[index]

        if searchResultPresentations.indices.contains(index) {
            let result = searchResultPresentations[index]
            guard result.scope.owner == owner,
                  result.scope.jid == jid,
                  result.scope.conversationTypeRawValue == conversationType.rawValue,
                  searchResultIdentity(for: legacyItem) == result.id else {
                return nil
            }

            let archivedId = result.anchor.archivedId.isNotEmpty
                ? result.anchor.archivedId
                : nil
            let primary = archivedId == nil && result.anchor.primary.isNotEmpty
                ? result.anchor.primary
                : nil
            guard archivedId != nil || primary != nil else {
                return nil
            }

            return ChatOpenMessageRequest(
                chatJid: result.scope.jid,
                owner: result.scope.owner,
                conversationType: conversationType,
                anchor: ChatMessageAnchorRef(
                    messagePrimary: primary,
                    archivedId: archivedId,
                    messageId: result.anchor.messageId.isNotEmpty
                        ? result.anchor.messageId
                        : nil,
                    authorId: result.anchor.authorId?.isNotEmpty == true
                        ? result.anchor.authorId
                        : nil,
                    bodyFingerprint: nil,
                    sourceDate: result.anchor.date
                ),
                highlight: true,
                markReadOnVisible: false,
                source: .search
            )
        }

        let archivedId = legacyItem.archivedId.isNotEmpty
            ? legacyItem.archivedId
            : nil
        let primary = archivedId == nil && legacyItem.primary.isNotEmpty
            ? legacyItem.primary
            : nil
        guard archivedId != nil || primary != nil else { return nil }
        return ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: primary,
                archivedId: archivedId,
                messageId: legacyItem.messageId.isNotEmpty
                    ? legacyItem.messageId
                    : nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: legacyItem.date
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .search
        )
    }

    private func setChatSearchTimelineHidden(_ hidden: Bool) {
        messagesCollectionView.isHidden = hidden
        messagesCollectionView.isUserInteractionEnabled = !hidden
        messagesCollectionView.accessibilityElementsHidden = hidden
    }

    internal func refreshChatSearchAccessibilityOrder() {
        guard isViewLoaded else { return }
        guard searchPresentationState.isActive else {
            view.accessibilityElements = nil
            messagesCollectionView.accessibilityElementsHidden = false
            return
        }

        if let calendarView = searchCalendarViewController?.viewIfLoaded,
           calendarView.superview === view,
           !calendarView.accessibilityElementsHidden {
            view.accessibilityElements = [calendarView]
            return
        }

        var elements: [Any] = []
        if searchNavigationView.superview === view, !searchNavigationView.isHidden {
            elements.append(searchNavigationView)
        }
        if let listView = searchResultsListViewController?.viewIfLoaded,
           listView.superview === view,
           !listView.isHidden,
           !listView.accessibilityElementsHidden {
            elements.append(listView)
        } else {
            elements.append(messagesCollectionView)
        }
        if searchNavigationButtonsView.superview === view,
           !searchNavigationButtonsView.isHidden,
           !searchNavigationButtonsView.accessibilityElementsHidden {
            elements.append(searchNavigationButtonsView)
        }
        elements.append(xabberInputView.searchPanel)
        view.accessibilityElements = elements
    }

    internal func installSearchNavigationButtons() {
        guard searchNavigationButtonsView.superview == nil else {
            return
        }
        let buttons = searchNavigationButtonsView
        buttons.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttons)
        let trailing = buttons.trailingAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.trailingAnchor,
            constant: -ChatSearchNavigationButtonsLayout.trailingInset
        )
        let bottom = buttons.bottomAnchor.constraint(
            equalTo: xabberInputView.topAnchor,
            constant: -ChatSearchNavigationButtonsLayout.bottomInset
        )
        searchNavigationButtonsTrailingConstraint = trailing
        searchNavigationButtonsBottomConstraint = bottom
        NSLayoutConstraint.activate([
            trailing,
            bottom,
            buttons.widthAnchor.constraint(
                equalToConstant: ChatSearchNavigationButtonsLayout.stackSize.width
            ),
            buttons.heightAnchor.constraint(
                equalToConstant: ChatSearchNavigationButtonsLayout.stackSize.height
            )
        ])
        view.bringSubviewToFront(buttons)
        renderSearchNavigationButtons(animated: false)
    }

    internal func renderSearchNavigationButtons(animated: Bool) {
        guard isViewLoaded else {
            return
        }
        searchNavigationButtonsView.render(
            ChatSearchNavigationButtonsRenderPolicy.state(
                presentation: searchPresentationState,
                navigationBusy: searchResultNavigationState.isBusy ||
                    searchOlderPageNavigationGate.hasPendingNavigation,
                canRequestOlderPage: searchOlderPageNavigationGate.canRequest
            ),
            animated: animated
        )
        if searchNavigationButtonsView.superview != nil {
            view.bringSubviewToFront(searchNavigationButtonsView)
            bringSearchInputOverlayToFront()
        }
        refreshChatSearchAccessibilityOrder()
    }

    internal func applySearchPanelStateFromPresentation() {
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
        cancelChatSearchCalendarDateResolution()
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
            reduceSearchPresentationState(.draftChanged(initialQuery))
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
            searchOlderPageNavigationGate.reset(generation: searchSession.generation)
            clearInChatSearchQuery(clearResults: true, panelState: .idle)
            searchTextObserver.accept(nil)
            return
        }

        if showSkeletonObserver.value {
            return
        }

        if searchPresentationState.query != normalizedText {
            reduceSearchPresentationState(.queryChanged(text ?? ""))
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
            searchOlderPageNavigationGate.reset(generation: searchSession.generation)
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
                    endArchiveSearchInteractiveCriticalSection(
                        queryID: queryId
                    )
                    _ = searchLocalProvider.cancel(queryId: queryId, generation: generation)
                    if let account = AccountManager.shared.find(for: owner) {
                        let conversation = archiveEngineConversationKey
                        Task {
                            await account.archiveEngine.cancelSearch(
                                conversation: conversation,
                                clientQueryID: queryId
                            )
                        }
                    }
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
                cancelChatSearchCalendarDateResolution()
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

        cancelChatSearchCalendarDateResolution()
        searchNavigationFeedbackCoordinator.cancel(
            generation: searchPresentationState.generation
        )
        reduceSearchPresentationState(.cancelSearch)
        applySearchSessionEffects(searchSession.cancel())
        searchOlderPageNavigationGate.reset(generation: searchSession.generation)
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
        let cancellationGeneration = searchPresentationState.generation
        let finalizeCancellation: () -> Void = { [weak self] in
            guard let self,
                  !self.searchPresentationState.isActive,
                  self.searchPresentationState.generation == cancellationGeneration else {
                return
            }
            self.hideSearchInputOverlay()
            self.xabberInputView.changeState(to: .normal)
            let inputMetrics = self.updateChatInputViewForCurrentKeyboardLayout(
                visibleKeyboardHeight: 0
            )
            self.updateChatCollectionInsets(
                inputHeight: inputMetrics.collectionObstructionHeight
            )
            self.becomeFirstResponder()
            self.applyChatDatasource(
                self.datasource,
                mode: .fullReload(keepOffset: true),
                animated: false,
                suppressDefaultBottomScroll: true,
                presentationOwner: .archiveEngine
            )
            _ = self.restoreNormalNavbarAfterSearchIfNeeded()
        }
        let shouldAnimate = ChatSearchMotionMutationPolicy.shouldAnimate(
            requestedAnimated: true,
            isNavigationTransitionActive: isNavigationTransitionActive,
            isPreparingFirstFrame: isPreparingStackedNavigationPresentation,
            isInteractiveKeyboardUpdate: false
        )
        transitionSearchChrome(
            to: .hidden,
            animated: shouldAnimate,
            completion: { _ in finalizeCancellation() }
        )
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
            endArchiveSearchInteractiveCriticalSection(
                queryID: currentSearchQueryId
            )
            if let generation = searchSessionGenerationByQueryId[currentSearchQueryId] {
                _ = searchLocalProvider.cancel(
                    queryId: currentSearchQueryId,
                    generation: generation
                )
            }
            searchSessionGenerationByQueryId.removeValue(forKey: currentSearchQueryId)
            if let account = AccountManager.shared.find(for: owner) {
                let conversation = archiveEngineConversationKey
                Task {
                    await account.archiveEngine.cancelSearch(
                        conversation: conversation,
                        clientQueryID: currentSearchQueryId
                    )
                }
            }
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
        let surfaceMode: ModernXabberInputView.SearchPanel.SurfaceMode =
            searchPresentationState.surfaceMode == .list ? .list : .chat
        xabberInputView.searchPanel.applyRenderState(
            renderState,
            surfaceMode: surfaceMode,
            animated: true
        )
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
            suppressDefaultBottomScroll: true,
            presentationOwner: .archiveEngine
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
                cleared.kind = .attributedText(ChatSearchHighlighter.removing(from: text))
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
        consumePendingOlderSearchResultNavigationIfReady(queryId: queryId)
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

    @discardableResult
    internal func replaceDetachedInChatSearchResultsIfCurrent(
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
        let residentResults = ChatSearchResultCollection.orderedAndDeduplicated(
            results.filter { $0.scope == expectedScope }
        )
        guard searchSession.replaceResidentResults(
            generation: generation,
            ids: residentResults.map(\.id)
        ) else {
            return false
        }
        searchResultPresentations = residentResults
        searchMessagesQueue = residentResults.map(Self.legacySearchMessage)
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
        if searchPresentationState.resultPhase == .results,
           searchResultPresentations.count >= searchPresentationState.resultCount {
            reduceSearchPresentationState(
                .resultsAppended(
                    count: searchResultPresentations.count,
                    generation: searchPresentationState.generation
                )
            )
        } else if searchResultsListViewController != nil {
            renderSearchResultSurfaceFromPresentation()
        }
    }

    internal var inChatSearchResultMappingContext: ChatSearchResultMappingContext {
        let localizedYou = ChatSearchLocalization.production().text(.outgoingSenderYou)
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
        endArchiveSearchInteractiveCriticalSection(queryID: queryId)
        reduceSearchPresentationState(
            .failed(generation: searchPresentationState.generation)
        )
        applySearchResults(emptyList: searchResultPresentations.isEmpty)
        setLoadingIndicatorVisible(false)
        postChatSearchAccessibilityAnnouncement(
            .searchFailure,
            generation: searchPresentationState.generation
        )
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
        guard let committedIndex = searchPresentationState.committedResultIndex,
              searchMessagesQueue.indices.contains(committedIndex) else {
            return -1
        }

        return committedIndex
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
        searchNavigationFeedbackCoordinator.cancel(
            generation: searchPresentationState.generation
        )
        guard isViewLoaded else {
            return
        }
        applySearchResultsPanelState(isLoadingContext: false)
        renderSearchNavigationButtons(animated: true)
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
            return nextIndex < searchMessagesQueue.count ? nextIndex : nil
        case .down:
            let nextIndex = index - 1
            return nextIndex >= 0 ? nextIndex : nil
        }
    }

    internal func scrollDirectionForSearchNavigation(
        from currentIndex: Int,
        to nextIndex: Int,
        requestedDirection: ChatDirection
    ) -> ChatDirection {
        requestedDirection
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
        renderSearchNavigationButtons(animated: true)
        scheduleStaleSearchResultPositioningCompletionFallback(finishedIndex: index)
    }

    internal func commitSearchResultNavigationPositioned(index: Int) {
        guard searchMessagesQueue.indices.contains(index) else {
            if !completeSearchResultNavigation(index: index) {
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
        _ = searchNavigationFeedbackCoordinator.commitPositioned(
            index: index,
            generation: searchPresentationState.generation
        )
        if !completeSearchResultNavigation(index: index) {
        }
    }

    private func hasActiveSearchResultAnchorWork() -> Bool {
        timelineInteractionState.locked ||
        pendingOpenMessageRequest != nil ||
        activeAnchorExecutionState != nil ||
        isApplyingAnchorWindow ||
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
        renderSearchNavigationButtons(animated: true)
        if hasActiveSearchResultAnchorWork() ||
            (xabberInputView?.searchPanel.renderState.isLoadingContext ?? false) {
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
            renderSearchNavigationButtons(animated: true)
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
            searchNavigationFeedbackCoordinator.cancel(
                generation: searchPresentationState.generation
            )
            setSearchResultsPanelContextLoading(false)
            refreshVisibleSearchSelection()
            renderSearchNavigationButtons(animated: true)
            return false
        }

        renderSearchNavigationButtons(animated: true)

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
        guard searchMessagesQueue.indices.contains(index),
              let request = makeSearchResultOpenMessageRequest(at: index) else {
            searchResultNavigationState = .idle
            searchNavigationFeedbackCoordinator.cancel(
                generation: searchPresentationState.generation
            )
            onNavigationFinished?()
            return
        }

        searchSession.beginPendingNavigation()
        chatScrollDirection = direction

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
        request.source == .search &&
            self.indexPathForLoadedMessage(request: request) == nil
    }

    private func navigateSearchResult(direction: ChatDirection) {
        guard let baseIndex = currentSearchResultNavigationBaseIndex() else {
            return
        }
        guard let nextIndex = nextSearchResultIndex(from: baseIndex, direction: direction) else {
            if direction == .up,
               baseIndex == searchMessagesQueue.count - 1 {
                requestOlderSearchResultsIfAvailable()
            }
            return
        }
        let scrollDirection = scrollDirectionForSearchNavigation(
            from: baseIndex,
            to: nextIndex,
            requestedDirection: direction
        )

        searchNavigationFeedbackCoordinator.prepare(
            expectedIndex: nextIndex,
            generation: searchPresentationState.generation
        )

        if timelineInteractionState.locked || searchResultNavigationState.isBusy {
            recordPendingSearchResultNavigation(index: nextIndex, scrollDirection: scrollDirection)
            return
        }

        openSearchResult(at: nextIndex, direction: scrollDirection)
    }

    internal func offerOlderSearchResultsCursor(
        _ cursor: String,
        queryId: String,
        generation: UInt64
    ) {
        guard isCurrentInChatSearchQuery(queryId: queryId),
              searchSessionGenerationByQueryId[queryId] == generation else {
            return
        }
        _ = searchOlderPageNavigationGate.offer(
            cursor: cursor,
            generation: generation,
            loadedResultCount: searchMessagesQueue.count
        )
        renderSearchNavigationButtons(animated: true)
    }

    internal func markOlderSearchResultsTerminal(generation: UInt64) {
        searchOlderPageNavigationGate.markTerminal(generation: generation)
        renderSearchNavigationButtons(animated: true)
    }

    internal func receiveArchiveEngineSearchState(_ state: ArchiveSearchState) {
        assert(Thread.isMainThread, "Archive search presentation is main-owned")
        let snapshot: ArchiveSearchSnapshot
        switch state {
        case .loading(let value),
             .results(let value),
             .retryableFailure(let value, _):
            snapshot = value
        }
        guard isCurrentInChatSearchQuery(queryId: snapshot.clientQueryID),
              let generation = searchSessionGenerationByQueryId[
                snapshot.clientQueryID
              ] else {
            return
        }

        switch state {
        case .loading:
            setLoadingIndicatorVisible(true)
        case .results:
            let mapped = snapshot.residentMessages.compactMap {
                ChatSearchResultMapper.map(
                    $0,
                    context: inChatSearchResultMappingContext
                )
            }
            guard replaceDetachedInChatSearchResultsIfCurrent(
                mapped,
                queryId: snapshot.clientQueryID
            ) else {
                return
            }
            applySearchResults(emptyList: searchResultPresentations.isEmpty)
            setLoadingIndicatorVisible(false)
            endArchiveSearchInteractiveCriticalSection(
                queryID: snapshot.clientQueryID
            )
            consumePendingOlderSearchResultNavigationIfReady(
                queryId: snapshot.clientQueryID
            )
            if snapshot.isComplete {
                markOlderSearchResultsTerminal(generation: generation)
                _ = finishInChatSearchQueryIfCurrent(
                    queryId: snapshot.clientQueryID,
                    emptyList: searchResultPresentations.isEmpty
                )
            } else if let cursor = snapshot.continuationCursor {
                offerOlderSearchResultsCursor(
                    cursor,
                    queryId: snapshot.clientQueryID,
                    generation: generation
                )
            }
        case .retryableFailure(_, let failure):
            setLoadingIndicatorVisible(false)
            endArchiveSearchInteractiveCriticalSection(
                queryID: snapshot.clientQueryID
            )
            applySearchResults(emptyList: searchResultPresentations.isEmpty)
            if failure.canRetry,
               snapshot.canRequestNextPage,
               searchResultPresentations.isNotEmpty {
                searchOlderPageNavigationGate.reset(generation: generation)
                searchNavigationFeedbackCoordinator.cancel(
                    generation: searchPresentationState.generation
                )
                offerOlderSearchResultsCursor(
                    "archive-engine-search-retry:\(snapshot.generation):\(snapshot.requestAttempt)",
                    queryId: snapshot.clientQueryID,
                    generation: generation
                )
                postChatSearchAccessibilityAnnouncement(
                    .searchFailure,
                    generation: searchPresentationState.generation
                )
            } else {
                _ = handleInChatSearchQueryFailure(
                    queryId: snapshot.clientQueryID
                )
                markOlderSearchResultsTerminal(generation: generation)
            }
        }
    }

    private func requestOlderSearchResultsIfAvailable() {
        let generation = searchOlderPageNavigationGate.generation
        guard let request = searchOlderPageNavigationGate.requestNavigation(generation: generation),
              let queryId = currentSearchQueryId else {
            searchOlderPageNavigationGate.markTerminal(generation: generation)
            renderSearchNavigationButtons(animated: true)
            return
        }
        if conversationType.isEncrypted {
            let didStartPage = searchLocalProvider.requestNextPage(
                queryId: queryId,
                generation: generation
            )
            guard didStartPage else {
                searchOlderPageNavigationGate.markTerminal(generation: generation)
                renderSearchNavigationButtons(animated: true)
                return
            }
            searchNavigationFeedbackCoordinator.prepare(
                expectedIndex: request.loadedResultCount,
                generation: searchPresentationState.generation
            )
            renderSearchNavigationButtons(animated: true)
            return
        }
        guard let account = AccountManager.shared.find(for: owner) else {
            endArchiveSearchInteractiveCriticalSection(queryID: queryId)
            searchOlderPageNavigationGate.markTerminal(generation: generation)
            renderSearchNavigationButtons(animated: true)
            return
        }
        beginArchiveSearchInteractiveCriticalSection(queryID: queryId)
        let conversation = archiveEngineConversationKey
        Task { @MainActor [weak self, weak account] in
            guard let self else { return }
            guard let account else {
                self.endArchiveSearchInteractiveCriticalSection(queryID: queryId)
                return
            }
            let didStartPage = await account.archiveEngine.requestNextSearchPage(
                conversation: conversation,
                clientQueryID: queryId
            )
            guard self.isCurrentInChatSearchQuery(queryId: queryId),
                  self.searchOlderPageNavigationGate.generation == generation else {
                self.endArchiveSearchInteractiveCriticalSection(queryID: queryId)
                return
            }
            guard didStartPage else {
                self.endArchiveSearchInteractiveCriticalSection(queryID: queryId)
                self.searchOlderPageNavigationGate.markTerminal(generation: generation)
                self.renderSearchNavigationButtons(animated: true)
                return
            }
            self.searchNavigationFeedbackCoordinator.prepare(
                expectedIndex: request.loadedResultCount,
                generation: self.searchPresentationState.generation
            )
            self.renderSearchNavigationButtons(animated: true)
        }
    }

    internal func consumePendingOlderSearchResultNavigationIfReady(queryId: String) {
        guard let generation = searchSessionGenerationByQueryId[queryId],
              let target = searchOlderPageNavigationGate.consumePendingNavigationTarget(
                  resultCount: searchMessagesQueue.count,
                  generation: generation
              ),
              searchMessagesQueue.indices.contains(target) else {
            return
        }
        reduceSearchPresentationState(
            .resultsAppended(
                count: searchMessagesQueue.count,
                generation: searchPresentationState.generation
            )
        )
        if timelineInteractionState.locked || searchResultNavigationState.isBusy {
            recordPendingSearchResultNavigation(index: target, scrollDirection: .up)
        } else {
            openSearchResult(at: target, direction: .up)
        }
    }

    private struct ResolvedJumpTarget {
        let primary: String
        let archivedId: String?
    }

    internal func queueOpenMessageRequest(
        _ request: ChatOpenMessageRequest,
        hooks: ChatAnchorExecutionHooks? = nil
    ) {
        let honorsMessageAnchor = ChatOpenMessageRequestHandlingPolicy
            .shouldHonorMessageAnchorRequest(source: request.source)

        guard honorsMessageAnchor else {
            self.handleSuppressedOpenMessageRequest(
                animated: hooks?.animatedScroll ?? false
            )
            return
        }

#if DEBUG || CHAT_PERFORMANCE_LAB
        self.performanceOpenMessageRequestAdmissionObserver?(
            request,
            self.isViewLoaded
        )
#endif
        let protectsInitialTargetFirstFrame =
            self.protectInitialTargetFirstFrameIfNeeded(for: request)
        if let executionState = self.activeAnchorExecutionState,
           executionState.request != request {
            self.invalidateProofScopedLocalTargetPreparation()
            self.invalidateArchiveWindowAuthoritativeEmptyApply()
            self.cancelDatasetMappingJobs()
            self.cancelActiveAnchorExecution(
                token: executionState.transactionToken,
                failure: .superseded,
                invokeFailureHook: false
            )
        }
        if !protectsInitialTargetFirstFrame,
           self.indexPathForLoadedMessage(request: request) != nil,
           self.shouldDeferLoadedAnchorForForeignTimelinePresentation() {
            if request.source == .search {
                self.markSearchResultNavigationLoadingContext(for: request)
                self.setSearchResultsPanelContextLoading(true)
            }
            self.pendingOpenMessageRequest = request
            self.activeAnchorExecutionHooks = hooks
            self.syncAnchorExecutionFlags()
            return
        }
        if !protectsInitialTargetFirstFrame,
           self.performLoadedOpenMessageRequestIfPossible(request, hooks: hooks) {
            return
        }
        if request.source == .search {
            self.markSearchResultNavigationLoadingContext(for: request)
            self.setSearchResultsPanelContextLoading(true)
        }
        self.pendingOpenMessageRequest = request
        self.activeAnchorExecutionHooks = hooks
        self.syncAnchorExecutionFlags()

        let canHandoffToArchive = self.isArchiveTargetHandoffReady(for: request)
        guard self.timelineSession?.verifiedScope != nil || canHandoffToArchive else {
            // A compact navigation route can deliver its exact intent before the
            // destination has installed a timeline session and archive demand.
            // Retain it for configure/start instead of turning missing lifecycle
            // admission into a terminal "target missing" result.
            return
        }
        let executionState = self.ensureActiveAnchorExecutionState(for: request)
        if protectsInitialTargetFirstFrame {
            guard canHandoffToArchive else { return }
            if self.submitProtectedInitialTargetFirstFrameToArchive(request) {
                return
            }
            self.failActiveAnchorExecution(
                token: executionState.transactionToken,
                failure: .targetMissing
            )
            return
        }
        if self.startProofScopedLocalOpenMessageRequestIfPossible(
            request,
            transactionToken: executionState.transactionToken
        ) {
            return
        }
        guard canHandoffToArchive else {
            return
        }
        if self.submitArchiveEngineTarget(request) {
            return
        }
        self.failActiveAnchorExecution(
            token: executionState.transactionToken,
            failure: .targetMissing
        )
    }

    private func isArchiveTargetHandoffReady(
        for request: ChatOpenMessageRequest
    ) -> Bool {
        guard request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              self.timelineSession != nil,
              self.archiveWindowStateTask != nil,
              self.archiveEnginePresentationDemandID != nil,
              self.archiveEnginePresentationDemandConversation ==
                self.archiveEngineConversationKey,
              self.archiveEnginePresentationDemandEngine != nil,
              AccountManager.shared.find(for: self.owner) != nil else {
            return false
        }
        return true
    }

    @discardableResult
    private func startProofScopedLocalOpenMessageRequestIfPossible(
        _ request: ChatOpenMessageRequest,
        transactionToken: ChatAnchorTransactionToken,
        attempt: Int = 0
    ) -> Bool {
        guard Thread.isMainThread,
              self.pendingOpenMessageRequest == request,
              self.activeAnchorExecutionState?.transactionToken ==
                transactionToken,
              self.proofScopedLocalTargetRequest == nil,
              let session = self.timelineSession,
              let scope = session.verifiedScope else {
            return false
        }
        guard case .local(let archiveCursor) =
                ChatProofScopedOpenTargetAdmission.route(
                    request: request,
                    verifiedScope: scope
                ) else {
            return false
        }
        guard self.isCurrentProofScopedLocalTargetPresentation(
            scope: scope,
            session: session
        ) else {
            // The current session proof already owns this cursor. If UIKit is
            // between proof and presentation receipts, wait for that receipt
            // instead of invalidating the scope and submitting duplicate MAM.
            return self.archiveWindowPendingSnapshot != nil ||
                self.archiveWindowPendingLiveEdgeAdmission != nil ||
                self.archiveWindowLiveEdgeApplyGeneration != nil ||
                self.committedTimelineLocalPresentationToken != nil ||
                self.timelineBoundaryRequest != nil ||
                self.showSkeletonObserver.value
        }

        self.archiveWindowApplyGeneration &+= 1
        let applyGeneration = self.archiveWindowApplyGeneration
        if self.deferArchiveEnginePresentationIfTimelineStoreApplyActive(
            applyGeneration: applyGeneration,
            work: { [weak self] in
                self?.performPendingOpenMessageRequestIfNeeded()
            }
        ) {
            return true
        }
        let contextID = UUID()
        let context = ChatProofScopedLocalTargetRequestContext(
            id: contextID,
            request: request,
            transactionToken: transactionToken,
            archiveCursor: archiveCursor,
            scope: scope,
            baseGeneration: session.snapshot.generation,
            applyGeneration: applyGeneration,
            searchGeneration:
                request.source == .search
                    ? self.searchPresentationState.generation
                    : nil,
            attempt: attempt
        )
        guard self.beginCommittedTimelineLocalPresentation(
            ChatCommittedTimelineLocalPresentationToken(
                id: contextID,
                purpose: .localTarget,
                scope: scope,
                sessionGeneration: context.baseGeneration,
                applyGeneration: applyGeneration
            )
        ) else {
            return true
        }
        self.proofScopedLocalTargetRequest = context
        self.isApplyingAnchorWindow = true
        self.syncAnchorExecutionFlags()
        self.setSearchAnchorNavigationScrollLockedIfNeeded(true, for: request)

        let disposition = session.prepareVerifiedLocalTarget(
            primary: request.anchor.messagePrimary,
            archiveCursor: archiveCursor,
            expectedGeneration: context.baseGeneration
        ) { [weak self, weak session] result in
            guard let self, let session else { return }
            self.receiveProofScopedLocalTargetPreparation(
                result,
                context: context,
                session: session
            )
        }
        guard disposition == .started else {
            let shouldRetry = context.attempt < 1
            self.failProofScopedLocalTargetPreparation(
                context,
                session: session,
                failure: .superseded,
                preservesPendingTarget: shouldRetry
            )
            if shouldRetry {
                self.retryProofScopedLocalTargetIfCurrent(context)
            }
            return true
        }
        return true
    }

    private func receiveProofScopedLocalTargetPreparation(
        _ result: ChatTimelineVerifiedTargetPreparationResult,
        context: ChatProofScopedLocalTargetRequestContext,
        session: ChatTimelineSession
    ) {
        assert(Thread.isMainThread)
        guard self.proofScopedLocalTargetContext(
            context,
            session: session,
            requiresBaseGeneration: true
        ) else {
            if self.proofScopedLocalTargetRequest?.id == context.id {
                let shouldRetry = context.attempt < 1
                self.failProofScopedLocalTargetPreparation(
                    context,
                    session: session,
                    failure: .superseded,
                    preservesPendingTarget: shouldRetry
                )
                if shouldRetry {
                    self.retryProofScopedLocalTargetIfCurrent(context)
                }
            }
            return
        }

        switch result {
        case .stale:
            let shouldRetry = context.attempt < 1
            self.failProofScopedLocalTargetPreparation(
                context,
                session: session,
                failure: .superseded,
                preservesPendingTarget: shouldRetry
            )
            if shouldRetry {
                self.retryProofScopedLocalTargetIfCurrent(context)
            }
        case .prepared(let prepared):
            let mappingJob = self.beginDatasetMappingJob()
            let mappingContext = self.captureDatasourceMappingContext()
            let base = session.snapshot
            let originalResidentWindow = self.residentDatasetWindow
            self.datasetMappingQueue.async { [weak self, weak session] in
                guard let self, let session else { return }
                guard !mappingJob.token.isCancelled else {
                    DispatchQueue.main.async { [weak self, weak session] in
                        guard let self, let session else { return }
                        let shouldRetry = context.attempt < 1
                        self.failProofScopedLocalTargetPreparation(
                            context,
                            session: session,
                            failure: .superseded,
                            preservesPendingTarget: shouldRetry
                        )
                        if shouldRetry {
                            self.retryProofScopedLocalTargetIfCurrent(context)
                        }
                    }
                    return
                }

                switch session.inspectPreparedVerifiedLocalTarget(prepared) {
                case .local(let candidate):
                    let mappingResult = self.mapDataset(
                        dataset: candidate.items,
                        context: mappingContext,
                        cancellationToken: mappingJob.token
                    )
                    DispatchQueue.main.async { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.applyPreparedProofScopedLocalTarget(
                            candidate,
                            prepared: prepared,
                            mappingResult: mappingResult,
                            mappingJob: mappingJob,
                            context: context,
                            base: base,
                            originalResidentWindow: originalResidentWindow,
                            session: session
                        )
                    }
                case .needsArchiveTarget:
                    DispatchQueue.main.async { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.failProofScopedLocalTargetPreparation(
                            context,
                            session: session,
                            failure: .targetMissing,
                            preservesPendingTarget: false
                        )
                    }
                case .invalidProof:
                    DispatchQueue.main.async { [weak self, weak session] in
                        guard let self, let session else { return }
                        self.failProofScopedLocalTargetPreparation(
                            context,
                            session: session,
                            failure: .targetDeleted,
                            preservesPendingTarget: false
                        )
                    }
                }
            }
        }
    }

    private func applyPreparedProofScopedLocalTarget(
        _ candidate: ChatTimelineSnapshot,
        prepared: ChatTimelinePreparedVerifiedLocalTarget,
        mappingResult: ChatDatasourceMappingResult,
        mappingJob: (
            generation: Int,
            token: ChatDatasetMappingCancellationToken
        ),
        context: ChatProofScopedLocalTargetRequestContext,
        base: ChatTimelineSessionSnapshot,
        originalResidentWindow: ChatDatasetWindow,
        session: ChatTimelineSession
    ) {
        assert(Thread.isMainThread)
        guard self.proofScopedLocalTargetContext(
            context,
            session: session,
            requiresBaseGeneration: true
        ),
        self.datasetMappingGeneration == mappingJob.generation,
        !mappingJob.token.isCancelled,
        !mappingResult.wasCancelled else {
            if self.proofScopedLocalTargetRequest?.id == context.id {
                let shouldRetry = context.attempt < 1
                self.failProofScopedLocalTargetPreparation(
                    context,
                    session: session,
                    failure: .superseded,
                    preservesPendingTarget: shouldRetry
                )
                if shouldRetry {
                    self.retryProofScopedLocalTargetIfCurrent(context)
                }
            }
            return
        }
        guard let target = candidate.items.first(where: { item in
            ArchiveCursor(rawValue: item.archivedId) == context.archiveCursor &&
                (context.request.anchor.messagePrimary.map {
                    item.primary == $0
                } ?? true)
        }),
        mappingResult.datasource.contains(where: {
            $0.primary == target.primary && !$0.isFakeMessage
        }) else {
            self.failProofScopedLocalTargetPreparation(
                context,
                session: session,
                failure: .targetDeleted,
                preservesPendingTarget: false
            )
            return
        }
        guard self.anchorTransactionGate.accept(
            .mapping, token: context.transactionToken
        ) == .accepted else {
            self.failProofScopedLocalTargetPreparation(
                context,
                session: session,
                failure: .superseded,
                preservesPendingTarget: false
            )
            return
        }

        let targetHeight = mappingResult.layoutSnapshot
            .layout(forPrimary: target.primary)?.cellSize.height ?? 0
        let restoreAnchor = ChatHistoryPageAnchor(
            primary: target.primary,
            viewportRelativeMinY: ChatAnchorCenteringPolicy
                .viewportRelativeMinY(
                    viewportHeight: self.messagesCollectionView.bounds.height,
                    targetHeight: targetHeight
                )
        )
        let commitReceipt = ChatProofScopedLocalTargetCommitReceipt()

        self.applyChatDatasource(
            mappingResult.datasource,
            mode: .fullReload(keepOffset: false),
            animated: false,
            invalidateLayout: false,
            preparedLayouts: mappingResult.layoutSnapshot,
            suppressDefaultBottomScroll: true,
            applyCategory: .default,
            anchorRestorePhase: .applyTransaction,
            anchorPrimary: target.primary,
            restoreAnchor: restoreAnchor,
            presentationOwner: .archiveEngine,
            presentationCommitMode: .atomicInitialFrame,
            transactionCommitAuthorization: { [weak self, weak session] in
                guard let self, let session,
                      self.proofScopedLocalTargetContext(
                        context,
                        session: session,
                        requiresBaseGeneration:
                            commitReceipt.snapshot == nil
                      ),
                      self.datasetMappingGeneration == mappingJob.generation,
                      !mappingJob.token.isCancelled else {
                    return false
                }
                if let committed = commitReceipt.snapshot {
                    return session.snapshot.generation == committed.generation
                }
                guard self.anchorTransactionGate.accept(
                    .apply, token: context.transactionToken
                ) == .accepted,
                case .local(let committed) =
                    session.commitPreparedVerifiedLocalTarget(prepared),
                committed.items.map(\.primary) == candidate.items.map(\.primary),
                committed.state == candidate.state else {
                    return false
                }
                commitReceipt.snapshot = committed
                return true
            },
            transactionCompletion: { [weak self, weak session] result in
                guard let self, let session else { return }
                self.handleProofScopedLocalTargetApplyResult(
                    result,
                    context: context,
                    base: base,
                    originalResidentWindow: originalResidentWindow,
                    commitReceipt: commitReceipt,
                    session: session
                )
            },
            completion: { [weak self, weak session] in
                guard let self, let session else { return }
                self.completeProofScopedLocalTargetApply(
                    context,
                    base: base,
                    originalResidentWindow: originalResidentWindow,
                    commitReceipt: commitReceipt,
                    session: session
                )
            }
        )
    }

    private func handleProofScopedLocalTargetApplyResult(
        _ result: ChatViewportTransactionResult,
        context: ChatProofScopedLocalTargetRequestContext,
        base: ChatTimelineSessionSnapshot,
        originalResidentWindow: ChatDatasetWindow,
        commitReceipt: ChatProofScopedLocalTargetCommitReceipt,
        session: ChatTimelineSession
    ) {
        guard case .failed = result else { return }
        if let committed = commitReceipt.snapshot,
           session.snapshot.generation == committed.generation,
           session.verifiedScope == context.scope {
            _ = session.restorePresentationSnapshot(
                base,
                verifiedScope: context.scope
            )
        }
        self.syncCurrentPage(with: originalResidentWindow)
        self.failProofScopedLocalTargetPreparation(
            context,
            session: session,
            failure: .targetMissing,
            preservesPendingTarget: false
        )
    }

    private func completeProofScopedLocalTargetApply(
        _ context: ChatProofScopedLocalTargetRequestContext,
        base: ChatTimelineSessionSnapshot,
        originalResidentWindow: ChatDatasetWindow,
        commitReceipt: ChatProofScopedLocalTargetCommitReceipt,
        session: ChatTimelineSession
    ) {
        guard self.proofScopedLocalTargetContext(
            context,
            session: session,
            requiresBaseGeneration: false
        ),
        let committed = commitReceipt.snapshot,
        session.snapshot.generation == committed.generation else {
            if let committed = commitReceipt.snapshot,
               session.snapshot.generation == committed.generation,
               session.verifiedScope == context.scope {
                _ = session.restorePresentationSnapshot(
                    base,
                    verifiedScope: context.scope
                )
            }
            self.syncCurrentPage(with: originalResidentWindow)
            self.failProofScopedLocalTargetPreparation(
                context,
                session: session,
                failure: .superseded,
                preservesPendingTarget: true
            )
            return
        }

        self.syncCurrentPage(with: ChatDatasetWindow(
            minIndex: 0,
            maxIndex: committed.items.count
        ))
        guard self.performLoadedOpenMessageRequestIfPossible(context.request) else {
            self.failActiveAnchorExecution(
                token: context.transactionToken,
                failure: .targetDeleted,
            )
            return
        }
    }

    private func failProofScopedLocalTargetPreparation(
        _ context: ChatProofScopedLocalTargetRequestContext,
        session: ChatTimelineSession,
        failure: ChatAnchorTransactionFailure,
        preservesPendingTarget: Bool
    ) {
        _ = session
        guard self.proofScopedLocalTargetRequest?.id == context.id else {
            return
        }
        self.proofScopedLocalTargetRequest = nil
        self.finishCommittedTimelineLocalPresentation(id: context.id)
        self.isApplyingAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setSearchAnchorNavigationScrollLockedIfNeeded(
            false,
            for: context.request
        )
        guard !preservesPendingTarget else {
            _ = self.anchorTransactionGate.begin(
                token: context.transactionToken,
                requestIdentity: self.anchorRequestIdentity(context.request)
            )
            return
        }
        self.failActiveAnchorExecution(
            token: context.transactionToken,
            failure: failure
        )
    }

    internal func invalidateProofScopedLocalTargetPreparation() {
        guard let context = self.proofScopedLocalTargetRequest else { return }
        self.proofScopedLocalTargetRequest = nil
        self.finishCommittedTimelineLocalPresentation(id: context.id)
        self.isApplyingAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setSearchAnchorNavigationScrollLockedIfNeeded(
            false,
            for: context.request
        )
        _ = self.anchorTransactionGate.begin(
            token: context.transactionToken,
            requestIdentity: self.anchorRequestIdentity(context.request)
        )
    }

    private func proofScopedLocalTargetContext(
        _ context: ChatProofScopedLocalTargetRequestContext,
        session: ChatTimelineSession,
        requiresBaseGeneration: Bool
    ) -> Bool {
        guard self.proofScopedLocalTargetRequest == context,
              self.pendingOpenMessageRequest == context.request,
              self.activeAnchorExecutionState?.transactionToken ==
                context.transactionToken,
              self.timelineSession === session,
              self.archiveWindowApplyGeneration == context.applyGeneration,
              self.committedTimelineLocalPresentationToken?.id == context.id,
              session.verifiedScope == context.scope,
              self.isCurrentProofScopedLocalTargetPresentation(
                  scope: context.scope,
                  session: session,
                  localPresentationID: context.id
              ),
              context.searchGeneration.map({
                self.searchPresentationState.generation == $0
              }) ?? true else {
            return false
        }
        return !requiresBaseGeneration ||
            session.snapshot.generation == context.baseGeneration
    }

    private func isCurrentProofScopedLocalTargetPresentation(
        scope: ChatTimelineVerifiedScope,
        session: ChatTimelineSession,
        localPresentationID: UUID? = nil
    ) -> Bool {
        guard self.committedTimelineScope(
                matching: scope,
                allowingLocalPresentationID: localPresentationID,
                allowsPendingLiveEdgeAdmission:
                    localPresentationID != nil
              ) == scope,
              session.verifiedScope == scope else {
            return false
        }
        return true
    }

    private func retryProofScopedLocalTargetIfCurrent(
        _ context: ChatProofScopedLocalTargetRequestContext
    ) {
        guard context.attempt < 1 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.pendingOpenMessageRequest == context.request,
                  self.activeAnchorExecutionState?.transactionToken ==
                    context.transactionToken else {
                return
            }
            if !self.startProofScopedLocalOpenMessageRequestIfPossible(
                context.request,
                transactionToken: context.transactionToken,
                attempt: context.attempt + 1
            ) {
                self.performPendingOpenMessageRequestIfNeeded()
            }
        }
    }

    private func resumePendingOpenMessageRequestThroughCurrentRoute() {
        guard self.proofScopedLocalTargetRequest == nil else { return }
        guard let request = self.pendingOpenMessageRequest,
              let executionState = self.activeAnchorExecutionState,
              executionState.request == request else {
            return
        }
        if self.isProtectingInitialTargetFirstFrame(request) {
            guard self.isArchiveTargetHandoffReady(for: request) else {
                return
            }
            if self.submitProtectedInitialTargetFirstFrameToArchive(request) {
                return
            }
            self.failActiveAnchorExecution(
                token: executionState.transactionToken,
                failure: self.typedAnchorResolutionFailure(for: request)
            )
            return
        }
        if self.startProofScopedLocalOpenMessageRequestIfPossible(
            request,
            transactionToken: executionState.transactionToken
        ) {
            return
        }
        guard self.isArchiveTargetHandoffReady(for: request) else {
            return
        }
        if self.submitArchiveEngineTarget(request) {
            return
        }
        self.failActiveAnchorExecution(
            token: executionState.transactionToken,
            failure: self.typedAnchorResolutionFailure(for: request)
        )
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

        let localPresentationID = self.proofScopedLocalTargetRequest?.id
        self.pendingOpenMessageRequest = nil
        self.activeAnchorExecutionState = nil
        self.activeAnchorExecutionHooks = nil
        self.proofScopedLocalTargetRequest = nil
        if let localPresentationID {
            self.finishCommittedTimelineLocalPresentation(
                id: localPresentationID
            )
        }
        self.isApplyingAnchorWindow = false
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

    internal func syncAnchorExecutionFlags() {
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
        let isBlockedByAnchorNavigation = self.isApplyingAnchorWindow
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

        self.isApplyingAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(true)
        self.timelineInteractionState.unlock()

        self.notifyAnchorPositioningStarted(token: transactionToken)
        if request.source == .search {
            self.setSearchResultsPanelContextLoading(false)
        }
        let positioningCompletion: (Bool) -> Void = { didPosition in
            guard didPosition else {
                self.failActiveAnchorExecution(
                    token: transactionToken,
                    failure: .targetDeleted
                )
                return
            }
            guard self.anchorTransactionGate.accept(
                .scroll,
                token: transactionToken
            ) == .accepted else {
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
        }
        #if DEBUG || CHAT_PERFORMANCE_LAB
        if let driver = self.loadedAnchorPositioningDriverForTests {
            driver(positioningCompletion)
        } else {
            self.positionMessage(
                primary: target.primary,
                archivedId: target.archivedId,
                highlight: request.highlight && !usesTransientHighlight,
                animated: activeHooks?.animatedScroll ?? false,
                preferredScrollDirection:
                    request.source == .search ? activeHooks?.direction : nil,
                completion: positioningCompletion
            )
        }
        #else
        self.positionMessage(
            primary: target.primary,
            archivedId: target.archivedId,
            highlight: request.highlight && !usesTransientHighlight,
            animated: activeHooks?.animatedScroll ?? false,
            preferredScrollDirection:
                request.source == .search ? activeHooks?.direction : nil,
            completion: positioningCompletion
        )
        #endif
        return true
    }

    /// Completes the semantic anchor transaction for a target that the archive
    /// transaction already placed in the committed first real frame. This path
    /// intentionally performs no offset calculation or scroll: navigation
    /// completion must not position the same request a second time.
    @discardableResult
    internal func finishCommittedInitialTargetFirstFramePositioningIfNeeded(
        request: ChatOpenMessageRequest,
        positionedPrimary: String
    ) -> Bool {
        guard Thread.isMainThread,
              self.pendingOpenMessageRequest == request,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              let section = self.datasourceSnapshot
                .primaryIndex[positionedPrimary],
              section < self.datasource.count,
              let target = self.datasourceItem(
                at: IndexPath(row: 0, section: section)
              ),
              target.primary == positionedPrimary else {
            return false
        }

        let indexPath = IndexPath(row: 0, section: section)
        let executionState = self.ensureActiveAnchorExecutionState(for: request)
        let transactionToken = executionState.transactionToken
        let usesTransientHighlight =
            request.source.usesTransientHighlight && request.highlight

        self.isApplyingAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(true)
        self.timelineInteractionState.unlock()

        self.notifyAnchorPositioningStarted(token: transactionToken)
        if request.source == .search {
            self.setSearchResultsPanelContextLoading(false)
        }
        guard self.anchorTransactionGate.accept(
                .scroll,
                token: transactionToken
              ) == .accepted else {
            return false
        }

        if usesTransientHighlight {
            self.applyTransientMessageHighlight(primary: positionedPrimary)
        } else if request.highlight {
            self.messagesCollectionView.visibleCells
                .compactMap { $0 as? MessageContentCell }
                .forEach { $0.setSelected(state: false) }
            self.initialTargetFirstFrameMessageCell(at: indexPath)?
                .setSelected(state: true)
        }
        self.retainPositionedMessageAnchor(
            primary: positionedPrimary,
            archivedId: target.archivedId,
            indexPath: indexPath
        )
        if self.inSearchMode.value || self.xabberInputView.state == .search {
            self.refreshVisibleSearchSelection()
        }
        self.scheduleMentionReadOnVisibleIfNeeded(
            for: request,
            positionedPrimary: positionedPrimary
        )
        self.finishActiveAnchorExecution(token: transactionToken)
        return self.pendingOpenMessageRequest == nil &&
            self.activeAnchorExecutionState == nil
    }

    private func initialTargetFirstFrameMessageCell(
        at indexPath: IndexPath
    ) -> MessageContentCell? {
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.transientMessageHighlightCellProviderForTests?(indexPath) ??
            self.messagesCollectionView.cellForItem(at: indexPath) as?
                MessageContentCell
#else
        self.messagesCollectionView.cellForItem(at: indexPath) as?
            MessageContentCell
#endif
    }

    private func initialAnchorExecutionState(
        for request: ChatOpenMessageRequest
    ) -> ChatAnchorExecutionState {
        ChatAnchorExecutionState(request: request)
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
        let localPresentationID = self.proofScopedLocalTargetRequest?.id
        self.pendingOpenMessageRequest = nil
        self.activeAnchorExecutionState = nil
        self.activeAnchorExecutionHooks = nil
        self.proofScopedLocalTargetRequest = nil
        #if DEBUG || CHAT_PERFORMANCE_LAB
        self.loadedAnchorPositioningDriverForTests = nil
        #endif
        self.isApplyingAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setSearchAnchorNavigationScrollLocked(false)
        if let localPresentationID {
            self.finishCommittedTimelineLocalPresentation(
                id: localPresentationID
            )
        }
        self.drainTimelinePresentationLanesAfterAnchorTerminal()
        self.setLoadingIndicatorVisible(false)
        self.setDatasourceLoadingEnabled(true)
        self.setSearchResultsPanelContextLoading(false)
        self.scheduleReadVisibleStableLayoutRetryIfNeeded()
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
        _ = self.clearInitialTargetFirstFrameProtectionIfMatching(
            executionState.request
        )
        let onFailed = self.activeAnchorExecutionHooks?.onFailed
        self.cleanupAnchorExecutionResources(executionState)
        self.clearAnchorExecutionPresentationState()
        let hasFailureHook = onFailed != nil
        if let onFailed {
            onFailed()
            return
        }
        guard ChatAnchorFailureRecoveryPolicy.shouldRunDefaultFailurePresentation(
            requestSource: executionState.request.source,
            hasFailureHook: hasFailureHook
        ) else { return }
        if case .search = executionState.request.source {
            self.postChatSearchAccessibilityAnnouncement(
                .positioningFailure,
                generation: self.searchPresentationState.generation
            )
        }
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
        invokeFailureHook: Bool,
        preservesViewportPresentation: Bool = false
    ) {
        guard let executionState = self.activeAnchorExecutionState,
              executionState.transactionToken == token,
              self.anchorTransactionGate.cancel(token: token, failure: failure) else {
            return
        }
        _ = self.clearInitialTargetFirstFrameProtectionIfMatching(
            executionState.request
        )
        let onFailed = invokeFailureHook ? self.activeAnchorExecutionHooks?.onFailed : nil
        self.cleanupAnchorExecutionResources(executionState)
        self.clearAnchorExecutionPresentationState(
            preservesViewportPresentation: preservesViewportPresentation
        )
        onFailed?()
    }

    private func cleanupAnchorExecutionResources(_ executionState: ChatAnchorExecutionState) {
        _ = executionState
    }

    private func clearAnchorExecutionPresentationState(
        preservesViewportPresentation: Bool = false
    ) {
        let localPresentationID = self.proofScopedLocalTargetRequest?.id
        self.pendingOpenMessageRequest = nil
        self.activeAnchorExecutionState = nil
        self.activeAnchorExecutionHooks = nil
        self.proofScopedLocalTargetRequest = nil
        #if DEBUG || CHAT_PERFORMANCE_LAB
        self.loadedAnchorPositioningDriverForTests = nil
        #endif
        self.isApplyingAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setSearchAnchorNavigationScrollLocked(false)
        if let localPresentationID {
            self.finishCommittedTimelineLocalPresentation(
                id: localPresentationID
            )
        }
        self.drainTimelinePresentationLanesAfterAnchorTerminal()
        guard !preservesViewportPresentation else {
            return
        }
        self.setLoadingIndicatorVisible(false)
        self.setDatasourceLoadingEnabled(true)
        self.setSearchResultsPanelContextLoading(false)
        self.scheduleReadVisibleStableLayoutRetryIfNeeded()
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
        let snapshot = timelineSession.snapshot

        if case .firstIncomingAfterBoundary(let boundaryArchivedId) =
            request.targetResolution,
           let normalizedBoundaryArchivedId =
            RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                boundaryArchivedId
            ),
           let boundaryDate = ChatInitialPositionPolicy.archiveDate(
                from: normalizedBoundaryArchivedId
           ) {
            let boundaryPosition = ChatTimelinePositionKey(
                boundary: ChatTimelineBoundary(
                    primary: normalizedBoundaryArchivedId,
                    archivedId: normalizedBoundaryArchivedId,
                    messageId: nil,
                    date: boundaryDate
                )
            )
            if let message = snapshot.items.first(where: {
                !$0.isDeleted &&
                    !$0.outgoing &&
                    RegularChatArchiveSyncStateStorageItem
                        .normalizedArchiveId($0.archivedId) !=
                        normalizedBoundaryArchivedId &&
                    ChatTimelinePositionKey(message: $0) > boundaryPosition
            }) {
                return (message, .unreadBoundaryAfter)
            }
            return nil
        }

        if request.source == .search {
            let anchor = request.anchor
            let lookups: [(ChatAnchorLookupMatchSource, String?, String?, String?)] = [
                (.primary, anchor.messagePrimary, nil, nil),
                (.archivedId, nil, anchor.archivedId, nil),
                (.messageId, nil, nil, anchor.messageId)
            ]
            for (source, primary, archivedId, messageId) in lookups {
                guard primary?.isNotEmpty == true ||
                        archivedId?.isNotEmpty == true ||
                        messageId?.isNotEmpty == true else {
                    continue
                }
                if let message = snapshot.item(
                    primary: primary,
                    archivedId: archivedId,
                    messageId: messageId
                ), !message.isDeleted {
                    return (message, source)
                }
            }
            return nil
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
            if let message = snapshot.item(
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
        _ = request
        return .targetMissing
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

        if abs(self.messagesCollectionView.contentOffset.y - targetOffsetY) <= 0.5 {
            finalize()
            return
        }

        guard animated else {
            self.messagesCollectionView.setContentOffset(
                CGPoint(
                    x: self.messagesCollectionView.contentOffset.x,
                    y: targetOffsetY
                ),
                animated: false
            )
            self.messagesCollectionView.layoutIfNeeded()
            finalize()
            return
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock(finalize)
        self.messagesCollectionView.setContentOffset(
            CGPoint(
                x: self.messagesCollectionView.contentOffset.x,
                y: targetOffsetY
            ),
            animated: true
        )
        CATransaction.commit()
    }

    private func centeredContentOffsetY(for indexPath: IndexPath) -> CGFloat? {
        guard let attributes = self.messagesCollectionView.layoutAttributesForItem(at: indexPath) else {
            return nil
        }

        return ChatAnchorContentOffsetPolicy.centeredOffsetY(
            targetMidY: attributes.frame.midY,
            viewportHeight: self.messagesCollectionView.bounds.height,
            contentHeight: self.messagesCollectionView.collectionViewLayout
                .collectionViewContentSize.height,
            adjustedContentInsets:
                self.messagesCollectionView.adjustedContentInset
        )
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
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.mentionReadOnVisibleSchedulingObserverForTests?(request)
#endif
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
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
                self.scheduleVisibleUnreadMentionReconciliation(
                    notificationPrimaries: notificationPrimaries,
                    positionedMessagePrimary: positionedPrimary
                )
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    internal func resolvePendingOpenMessageRequestAfterAuthoritativeEmpty(
        target: ArchiveWindowLocator
    ) -> Bool {
        guard let request = self.pendingOpenMessageRequest else {
            return false
        }
        let requestedTarget: ArchiveWindowLocator?
        if let rawArchiveID = request.anchor.archivedId,
           let cursor = ArchiveCursor(rawValue: rawArchiveID) {
            requestedTarget = .archiveID(cursor)
        } else if let date = request.anchor.sourceDate {
            requestedTarget = .timestamp(date)
        } else {
            requestedTarget = nil
        }
        let action = ChatAuthoritativeEmptyPendingTargetPolicy.action(
            emptyTarget: target,
            requestedTarget: requestedTarget
        )
        #if DEBUG || CHAT_PERFORMANCE_LAB
        self.authoritativeEmptyPendingTargetActionObserverForTests?(action)
        #endif
        let executionState = self.ensureActiveAnchorExecutionState(for: request)
        self.syncAnchorExecutionFlags()
        if action == .submitArchiveTarget,
           self.submitArchiveEngineTarget(request) {
            return true
        }
        self.failActiveAnchorExecution(
            token: executionState.transactionToken,
            failure: self.typedAnchorResolutionFailure(for: request)
        )
        return false
    }

    internal func performPendingOpenMessageRequestIfNeeded() {
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
                self.performPendingOpenMessageRequestIfNeeded()
            }
            return
        }

        if ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
            isPresentationActive: true,
            state: self.archiveWindowState,
            committedCoverageGeneration:
                self.archiveWindowCommittedCoverageGeneration,
            pendingSnapshot: self.archiveWindowPendingSnapshot,
            isShowingSkeleton: self.showSkeletonObserver.value,
            verifiedScope: self.timelineSession?.verifiedScope
        ) {
            return
        }

        let localPresentationID = self.proofScopedLocalTargetRequest.flatMap {
            $0.request == request ? $0.id : nil
        }
        if self.indexPathForLoadedMessage(request: request) != nil,
           self.shouldDeferLoadedAnchorForForeignTimelinePresentation(
                allowingLocalPresentationID: localPresentationID
           ) {
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
        guard self.timelineSession?.verifiedScope != nil ||
                self.isArchiveTargetHandoffReady(for: request) else {
            return
        }
        if self.activeAnchorExecutionState == nil {
            _ = self.ensureActiveAnchorExecutionState(for: request)
            self.syncAnchorExecutionFlags()
        }

#if DEBUG || CHAT_PERFORMANCE_LAB
        if self.pendingOpenMessageGenericExecutionInterceptorForTests?() == true {
            return
        }
#endif

        self.resumePendingOpenMessageRequestThroughCurrentRoute()
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
        searchChromeTransitionCoordinator.cleanupAnimations(finalState: .visible)
        if searchPresentationState.surfaceMode == .list {
            reduceSearchPresentationState(.closeList)
        } else if makeChatSearchResultsListRenderModel()?.canPresent == true {
            reduceSearchPresentationState(.openList)
        }
    }

    internal func onSearchPanelOpenCalendar() {
        guard let request = searchPresentationState.calendarPresentationRequest else {
            return
        }
        searchChromeTransitionCoordinator.cleanupAnimations(finalState: .visible)
        request.prepareForPresentation(
            resignKeyboard: { [weak self] in
                guard let self else { return }
                view.endEditing(true)
                searchBar.endEditing(true)
                searchInputBar.endEditing(true)
            },
            layoutBottomGuide: { [weak self] in
                self?.view.layoutIfNeeded()
            }
        )
        reduceSearchPresentationState(request.event)
        guard searchPresentationState.surfaceMode == .calendar else { return }

        let calendarController = ChatSearchCalendarViewController(
            model: ChatSearchCalendarModel(
                calendar: .autoupdatingCurrent,
                locale: .autoupdatingCurrent,
                clock: ChatSearchCalendarSystemClock()
            ),
            animationSpec: searchAnimationSpec
        )
        calendarController.onCancel = { [weak self] in
            self?.dismissChatSearchCalendar(animated: true)
        }
        calendarController.onComplete = { [weak self] selectedTimestamp in
            self?.completeChatSearchCalendar(at: selectedTimestamp, animated: true)
        }
        searchCalendarViewController = calendarController
        calendarController.install(in: self, containerView: view)
        let generation = searchPresentationState.generation
        calendarController.present(
            generation: generation,
            animated: true,
            focusReturnView: xabberInputView.searchPanel.calendarButton,
            isGenerationCurrent: { [weak self] candidateGeneration in
                guard let self else { return false }
                return searchPresentationState.isActive &&
                    searchPresentationState.surfaceMode == .calendar &&
                    searchPresentationState.generation == candidateGeneration
            }
        )
        refreshChatSearchAccessibilityOrder()
    }

    internal func dismissChatSearchCalendar(animated: Bool) {
        guard searchPresentationState.surfaceMode == .calendar else { return }
        guard let calendarController = searchCalendarViewController else {
            reduceSearchPresentationState(.cancelCalendar)
            return
        }
        let generation = searchPresentationState.generation
        calendarController.dismiss(
            generation: generation,
            animated: animated,
            isGenerationCurrent: { [weak self] candidateGeneration in
                guard let self else { return false }
                return searchPresentationState.isActive &&
                    searchPresentationState.surfaceMode == .calendar &&
                    searchPresentationState.generation == candidateGeneration
            },
            completion: { [weak self, weak calendarController] in
                guard let self,
                      self.searchCalendarViewController === calendarController else {
                    return
                }
                self.searchCalendarViewController = nil
                if self.searchPresentationState.surfaceMode == .calendar,
                   self.searchPresentationState.generation == generation {
                    self.reduceSearchPresentationState(.cancelCalendar)
                }
            }
        )
    }

    internal func removeChatSearchCalendarControllerImmediately() {
        searchCalendarViewController?.reset()
        searchCalendarViewController = nil
    }

    internal func completeChatSearchCalendar(at selectedTimestamp: Date, animated: Bool) {
        assert(Thread.isMainThread, "Calendar date completion must run on the main thread")
        guard searchPresentationState.isActive,
              searchPresentationState.surfaceMode == .calendar,
              pendingSearchCalendarDateRequest == nil else {
            return
        }

        let scope = ChatSearchResult.Scope(
            owner: owner,
            jid: jid,
            conversationTypeRawValue: conversationType.rawValue
        )
        let nextPresentationGeneration = searchPresentationState.generation &+ 1
        let request = ChatSearchCalendarDateRequest(
            id: UUID(),
            generation: UInt64(max(0, nextPresentationGeneration)),
            scope: scope,
            selectedTimestamp: selectedTimestamp
        )
        pendingSearchCalendarDateRequest = request
        setChatSearchCalendarDateResolutionLoading(true)

        let beginResolution: () -> Void = { [weak self] in
            self?.beginChatSearchCalendarDateResolution(request)
        }
        guard let calendarController = searchCalendarViewController else {
            beginResolution()
            return
        }
        let calendarGeneration = searchPresentationState.generation
        calendarController.dismiss(
            generation: calendarGeneration,
            animated: animated,
            isGenerationCurrent: { [weak self] candidateGeneration in
                guard let self else { return false }
                return self.searchPresentationState.isActive &&
                    self.searchPresentationState.surfaceMode == .calendar &&
                    self.searchPresentationState.generation == candidateGeneration &&
                    self.pendingSearchCalendarDateRequest?.id == request.id
            },
            completion: { [weak self, weak calendarController] in
                guard let self,
                      self.searchCalendarViewController === calendarController else {
                    return
                }
                self.searchCalendarViewController = nil
                beginResolution()
            }
        )
    }

    @discardableResult
    internal func cancelChatSearchCalendarDateResolution() -> Bool {
        assert(Thread.isMainThread, "Calendar date cancellation must run on the main thread")
        let hadPending = pendingSearchCalendarDateRequest != nil
        pendingSearchCalendarDateRequest = nil
        if case .resolvingDate = searchPresentationState.positioningPhase {
            reduceSearchPresentationState(
                .dateResolutionFinished(generation: searchPresentationState.generation)
            )
        }
        if hadPending {
            setChatSearchCalendarDateResolutionLoading(false)
        }
        return hadPending
    }

    private func beginChatSearchCalendarDateResolution(
        _ request: ChatSearchCalendarDateRequest
    ) {
        guard pendingSearchCalendarDateRequest?.id == request.id,
              searchPresentationState.isActive,
              searchPresentationState.surfaceMode == .calendar,
              currentChatSearchScopeMatches(request.scope) else {
            pendingSearchCalendarDateRequest = nil
            setChatSearchCalendarDateResolutionLoading(false)
            return
        }
        pendingSearchCalendarDateRequest = nil
        reduceSearchPresentationState(.completeCalendarDate(request.selectedTimestamp))
        guard UInt64(max(0, searchPresentationState.generation)) == request.generation else {
            reduceSearchPresentationState(
                .dateResolutionFinished(generation: searchPresentationState.generation)
            )
            setChatSearchCalendarDateResolutionLoading(false)
            return
        }

        restoreNormalChatChromeForCalendarDateResolution()
        reduceSearchPresentationState(
            .dateResolutionFinished(generation: Int(request.generation))
        )
        setChatSearchCalendarDateResolutionLoading(false)
        guard currentChatSearchScopeMatches(request.scope) else {
            return
        }
        let openRequest = ChatOpenMessageRequest(
            chatJid: jid,
            owner: owner,
            conversationType: conversationType,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: nil,
                messageId: nil,
                authorId: nil,
                bodyFingerprint: nil,
                sourceDate: request.selectedTimestamp
            ),
            highlight: true,
            markReadOnVisible: false,
            source: .search
        )
        chatScrollDirection = .up
        queueOpenMessageRequest(
            openRequest,
            hooks: ChatAnchorExecutionHooks(
                direction: .up,
                animatedScroll: true,
                onFailed: { [weak self] in
                    self?.announceChatSearchCalendarDateHasNoMessage(
                        generation: Int(request.generation)
                    )
                },
                onPositioned: nil
            )
        )
    }

    private func restoreNormalChatChromeForCalendarDateResolution() {
        searchChromeTransitionCoordinator.cleanupAnimations(finalState: .hidden)
        searchNavigationFeedbackCoordinator.cancel(
            generation: searchPresentationState.generation
        )
        applySearchSessionEffects(searchSession.cancel())
        searchOlderPageNavigationGate.reset(generation: searchSession.generation)
        clearInChatSearchQuery(clearResults: true, panelState: .idle)
        pendingSearchActivationRequest = nil
        searchBar.text = nil
        searchTextObserver.accept(nil)
        inSearchMode.accept(false)

        guard isViewLoaded else {
            setChatSearchCalendarDateResolutionLoading(true)
            return
        }
        searchInputBar.text = nil
        searchBar.endEditing(true)
        searchInputBar.endEditing(true)
        hideSearchInputOverlay()
        xabberInputView.changeState(to: .normal)
        let inputMetrics = updateChatInputViewForCurrentKeyboardLayout(
            visibleKeyboardHeight: 0
        )
        updateChatCollectionInsets(
            inputHeight: inputMetrics.collectionObstructionHeight
        )
        _ = restoreNormalNavbarAfterSearchIfNeeded()
        setChatSearchCalendarDateResolutionLoading(true)
    }

    private func setChatSearchCalendarDateResolutionLoading(_ isLoading: Bool) {
        isChatSearchCalendarDateResolutionLoading = isLoading
        setLoadingIndicatorVisible(isLoading)
    }

    private func currentChatSearchScopeMatches(_ scope: ChatSearchResult.Scope) -> Bool {
        scope.owner == owner &&
            scope.jid == jid &&
            scope.conversationTypeRawValue == conversationType.rawValue
    }

    private func announceChatSearchCalendarDateHasNoMessage(generation: Int) {
        postChatSearchAccessibilityAnnouncement(
            .dateNoMessage,
            generation: generation,
            handler: chatSearchCalendarDateAnnouncementHandler
        )
    }

    private func presentChatSearchCalendarDateResolutionError(generation: Int) {
        let handler = chatSearchCalendarDateErrorHandler
        postChatSearchAccessibilityAnnouncement(
            .dateFailure,
            generation: generation,
            handler: handler
        )
        guard handler == nil, isViewLoaded else {
            return
        }
        view.makeToast(ChatSearchLocalization.production().text(.announcementSearchError))
    }

    private func postChatSearchAccessibilityAnnouncement(
        _ event: ChatSearchAccessibilityAnnouncementState.Event,
        generation: Int,
        handler: ((String) -> Void)? = nil
    ) {
        guard let message = chatSearchAccessibilityAnnouncementState.message(
            for: event,
            generation: generation,
            localization: .production()
        ) else {
            return
        }
        if let handler {
            handler(message)
        } else if let chatSearchAccessibilityAnnouncementHandler {
            chatSearchAccessibilityAnnouncementHandler(message)
        } else {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
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
        let cell: MessageContentCell?
#if DEBUG || CHAT_PERFORMANCE_LAB
        cell = self.transientMessageHighlightCellProviderForTests?(indexPath) ??
            self.messagesCollectionView.cellForItem(at: indexPath) as?
                MessageContentCell
#else
        cell = self.messagesCollectionView.cellForItem(at: indexPath) as?
            MessageContentCell
#endif
        guard let cell else {
            return
        }

        let revision = self.anchorDisplayRevision(for: self.datasource[section])
        let overlay = ChatAnchorHighlightOverlay.install(
            on: cell,
            primary: primary,
            revision: revision
        )
        guard ChatAnchorHighlightOverlay.representedPrimary(in: cell) == primary,
              ChatAnchorHighlightOverlay.representedRevision(in: cell) == revision else {
            return
        }

        let animations = {
            overlay.alpha = 0
        }
        let completion: (Bool) -> Void = {
            [weak cell, weak overlay] _ in
                guard let cell, let overlay else {
                    return
                }
                _ = ChatAnchorHighlightOverlay.remove(
                    from: cell,
                    ifCurrent: overlay
                )
        }
#if DEBUG || CHAT_PERFORMANCE_LAB
        if self.defersTransientMessageHighlightAnimationForTests {
            animations()
            self.transientMessageHighlightAnimationCompletionForTests =
                completion
            return
        }
#endif
        UIView.animate(
            withDuration: 0.25,
            delay: 0.55,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: animations,
            completion: completion
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
        guard self.timelineInteractionState.isUnlocked else {
            return
        }
        if self.isUnreadMentionNavigationInFlight {
#if DEBUG || CHAT_PERFORMANCE_LAB
            if let notificationPrimary = target.notificationPrimary,
               self.claimedUnreadMentionBadgeNotificationPrimary ==
                    notificationPrimary {
                self.unreadMentionBadgeDuplicateDropObserverForTests?(
                    notificationPrimary
                )
            }
#endif
            return
        }
        guard let notificationPrimary = target.notificationPrimary else {
            self.navigateToUnreadMention(
                target,
                direction: self.unreadMentionNavigationDirection(for: target)
            )
            return
        }
        guard self.claimedUnreadMentionBadgeNotificationPrimary !=
                notificationPrimary else {
#if DEBUG || CHAT_PERFORMANCE_LAB
            self.unreadMentionBadgeDuplicateDropObserverForTests?(
                notificationPrimary
            )
#endif
            return
        }
        self.claimedUnreadMentionBadgeNotificationPrimary = notificationPrimary

        let selection = self.resolveUnreadMentionBadgeSelection(
            notificationPrimary: notificationPrimary
        )
        let effectiveResolution: NotificationsMentionOpenResolution
        let selectedNotificationPrimary: String?
        switch selection.resolution {
        case .exact(let request, let invalidatedNotificationPrimary):
            guard request.owner == self.owner,
                  request.chatJid == self.jid,
                  request.conversationType == self.conversationType,
                  request.source == .mentionNotification,
                  let exactNotificationPrimary =
                    selection.selectedNotificationPrimary,
                  let exactTarget = self.unreadMentionNavigationTarget(
                    request: request,
                    notificationPrimary: exactNotificationPrimary
                  ) else {
                effectiveResolution = .unavailable(.sourceChatUnavailable)
                selectedNotificationPrimary = nil
                break
            }
            effectiveResolution = .exact(
                request,
                invalidatedNotificationPrimary:
                    invalidatedNotificationPrimary
            )
            selectedNotificationPrimary = exactNotificationPrimary
#if DEBUG || CHAT_PERFORMANCE_LAB
            self.unreadMentionBadgeOpenResolutionObserverForTests?(
                effectiveResolution,
                selectedNotificationPrimary
            )
#endif
            self.navigateToUnreadMention(
                exactTarget,
                direction: self.unreadMentionNavigationDirection(
                    for: exactTarget
                )
            )
            return
        case .unavailable(let reason):
            effectiveResolution = .unavailable(reason)
            selectedNotificationPrimary = nil
        }

#if DEBUG || CHAT_PERFORMANCE_LAB
        self.unreadMentionBadgeOpenResolutionObserverForTests?(
            effectiveResolution,
            selectedNotificationPrimary
        )
#endif
    }

    private func resolveUnreadMentionBadgeSelection(
        notificationPrimary: String
    ) -> NotificationsMentionOpenSelection {
        do {
            let realm = try WRealm.safe()
            var selection = NotificationsMentionOpenSelection(
                resolution: .unavailable(.notificationUnavailable),
                selectedNotificationPrimary: nil
            )
            try realm.write {
                selection = NotificationsMentionOpenRouter.resolveSelection(
                    notificationPrimary: notificationPrimary,
                    in: realm
                )
            }
            return selection
        } catch {
            DDLogDebug(
                "ChatViewController: \(#function). \(error.localizedDescription)"
            )
            return NotificationsMentionOpenSelection(
                resolution: .unavailable(.notificationUnavailable),
                selectedNotificationPrimary: nil
            )
        }
    }

    private func unreadMentionNavigationTarget(
        request: ChatOpenMessageRequest,
        notificationPrimary: String
    ) -> ChatUnreadMentionNavigationTarget? {
        guard notificationPrimary.isNotEmpty else {
            return nil
        }
        let indexedItem = self.unreadMentionItems.first {
            $0.notificationPrimary == notificationPrimary
        }
        let messagePrimary = indexedItem?.messagePrimary ??
            request.anchor.messagePrimary
        return ChatUnreadMentionNavigationTarget(
            notificationPrimary: notificationPrimary,
            messagePrimary: messagePrimary,
            archivedId: request.anchor.archivedId,
            messageId: request.anchor.messageId,
            authorId: request.anchor.authorId,
            date: request.anchor.sourceDate ??
                indexedItem?.date ?? Date(timeIntervalSince1970: 0),
            observerIndex: messagePrimary.flatMap {
                self.timelineSession?.snapshot.residentIndex.index(
                    primary: $0
                )
            }
        )
    }

    private func unreadMentionNavigationDirection(
        for target: ChatUnreadMentionNavigationTarget
    ) -> ChatDirection {
        let residentIndex = self.timelineSession?.snapshot.residentIndex
        return (target.observerIndex ?? Int.max) <
            (self.visibleRealMessagePrimaries().compactMap {
                residentIndex?.index(primary: $0)
            }.min() ?? Int.max)
            ? .down
            : .up
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
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.unreadMentionBadgeSuccessFeedbackObserverForTests?()
#endif
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
        let failNavigation: () -> Void = { [weak self] in
            if self?.claimedUnreadMentionBadgeNotificationPrimary ==
                target.notificationPrimary {
                self?.claimedUnreadMentionBadgeNotificationPrimary = nil
            }
            finishNavigation()
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
                onFailed: failNavigation,
                onPositioned: finishNavigation
            )
        )
    }
}

extension ChatViewController {

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
            self.postChatSearchAccessibilityAnnouncement(
                .noResults,
                generation: self.searchPresentationState.generation
            )
        }
        self.setFloatingDateVisible(true)
    }
}
