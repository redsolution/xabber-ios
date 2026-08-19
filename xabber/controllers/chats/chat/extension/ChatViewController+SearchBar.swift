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

enum ChatAnchorContextPrefetchDispatchPhase: Equatable {
    case beforePositioning
}

enum ChatRemoteArchiveTransportOwnership: Equatable {
    case anchorTarget
    case anchorContext
    case detachedBackground
}

enum ChatAnchorContextPrefetchDispatchPolicy {
    static func phase(
        for mode: ChatAnchorContextPrefetchMode
    ) -> ChatAnchorContextPrefetchDispatchPhase {
        _ = mode
        return .beforePositioning
    }
}

enum ChatAnchorContextPrefetchModePolicy {
    static func mode(
        for source: ChatOpenMessageRequestSource,
        hasLocalMatch: Bool,
        isSynced: Bool,
        hasCommittedInitialContent: Bool = true
    ) -> ChatAnchorContextPrefetchMode {
        _ = source
        _ = isSynced
        if hasLocalMatch && hasCommittedInitialContent {
            return .background
        }

        return .blocking
    }
}

enum ChatAnchorContextMaterializationPolicy {
    static func isReady(
        snapshotGeneration: UInt64,
        baselineGeneration: UInt64?,
        targetIsMaterialized: Bool,
        olderLocalCount: Int,
        newerLocalCount: Int,
        requiredOlderLocalCount: Int,
        requiredNewerLocalCount: Int,
        olderBoundary: ChatAnchorContextCoverageBoundary,
        newerBoundary: ChatAnchorContextCoverageBoundary,
        persistedMessageCount: Int
    ) -> Bool {
        guard targetIsMaterialized else { return false }
        if persistedMessageCount > 0,
           let baselineGeneration,
           snapshotGeneration <= baselineGeneration {
            return false
        }
        let olderReady = olderLocalCount >= requiredOlderLocalCount ||
            olderBoundary == .complete
        let newerReady = newerLocalCount >= requiredNewerLocalCount ||
            newerBoundary == .complete
        return olderReady && newerReady
    }
}

/// Owns persistence for archive work that intentionally outlives the anchor
/// presentation transaction. It contains no view-controller reference: raw
/// `<fin>` and disconnect delivery can safely arrive after back navigation.
final class ChatDetachedRemoteHistoryPersistenceTransaction {
    typealias Flush = (
        _ queryId: String,
        _ state: MessageArchivePageEndState,
        _ completion: @escaping () -> Void
    ) -> Void
    typealias Unregister = (
        _ queryId: String,
        _ completion: @escaping () -> Void
    ) -> Void

    private enum Phase: Equatable {
        case active
        case finalizing
        case terminal
    }

    private let owner: String
    private let lock = NSLock()
    private var phasesByQueryId: [String: Phase]
    private var failureTokensByQueryId: [String: MessageArchiveRequestFailureDispatcher.Token] = [:]
    private let terminal: ((String) -> Void)?
    private let flush: Flush
    private let unregister: Unregister

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        queryIds: Set<String>,
        terminal: ((String) -> Void)? = nil,
        flush: Flush? = nil,
        unregister: Unregister? = nil
    ) {
        self.owner = owner
        self.phasesByQueryId = Dictionary(
            uniqueKeysWithValues: queryIds
                .filter { $0.isNotEmpty }
                .map { ($0, Phase.active) }
        )
        self.terminal = terminal
        self.flush = flush ?? { queryId, state, completion in
            ChatRemoteHistoryCompletionCoordinator.flushQueryMessagesAsync(
                owner: owner,
                queryId: queryId,
                state: state,
                conversationJid: jid,
                conversationType: conversationType
            ) { _ in
                completion()
            }
        }
        self.unregister = unregister ?? { queryId, completion in
            ChatRemoteHistoryCompletionCoordinator.unregisterPersistenceSource(
                owner: owner,
                queryId: queryId,
                completion: completion
            )
        }

        self.phasesByQueryId.keys.forEach { queryId in
            let token = MessageArchiveRequestFailureDispatcher.register(
                owner: owner,
                queryId: queryId,
                delivery: .synchronous
            ) { [self] event in
                self.receiveFailure(queryId: event.queryId)
            }
            self.failureTokensByQueryId[queryId] = token
        }
    }

    var requestCallbacks: MessageArchiveManager.RequestCallbacks {
        MessageArchiveManager.RequestCallbacks(
            onEndPage: { [self] queryId, state, _, _, _ in
                self.receiveFinal(queryId: queryId, state: state)
            }
        )
    }

    func registerPersistenceSource(
        _ manager: MessageManager?,
        archiveManager: MessageArchiveManager? = nil,
        queryId: String
    ) {
        guard let manager,
              isActive(queryId: queryId) else {
            return
        }
        ChatRemoteHistoryCompletionCoordinator.registerPersistenceSource(
            manager,
            archiveManager: archiveManager,
            owner: owner,
            queryId: queryId
        )
    }

    func cancel() {
        let queryIds: [String]
        let tokens: [MessageArchiveRequestFailureDispatcher.Token]
        lock.lock()
        queryIds = phasesByQueryId.compactMap { queryId, phase in
            phase == .active ? queryId : nil
        }
        queryIds.forEach { queryId in
            phasesByQueryId[queryId] = .terminal
        }
        tokens = queryIds.compactMap { failureTokensByQueryId.removeValue(forKey: $0) }
        lock.unlock()

        tokens.forEach(MessageArchiveRequestFailureDispatcher.unregister)
        queryIds.forEach { queryId in
            unregister(queryId) { [terminal] in
                terminal?(queryId)
            }
        }
    }

    private func isActive(queryId: String) -> Bool {
        lock.lock()
        let isActive = phasesByQueryId[queryId] == .active
        lock.unlock()
        return isActive
    }

    private func receiveFinal(
        queryId: String,
        state: MessageArchivePageEndState
    ) {
        let failureToken: MessageArchiveRequestFailureDispatcher.Token?
        lock.lock()
        guard phasesByQueryId[queryId] == .active else {
            lock.unlock()
            return
        }
        phasesByQueryId[queryId] = .finalizing
        failureToken = failureTokensByQueryId.removeValue(forKey: queryId)
        lock.unlock()

        if let failureToken {
            MessageArchiveRequestFailureDispatcher.unregister(failureToken)
        }
        flush(queryId, state) { [self] in
            unregister(queryId) { [self] in
                finish(queryId: queryId, expectedPhase: .finalizing)
            }
        }
    }

    private func receiveFailure(queryId: String) {
        finish(queryId: queryId, expectedPhase: .active)
    }

    private func finish(queryId: String, expectedPhase: Phase) {
        let shouldNotify: Bool
        lock.lock()
        shouldNotify = phasesByQueryId[queryId] == expectedPhase
        if shouldNotify {
            phasesByQueryId[queryId] = .terminal
            failureTokensByQueryId.removeValue(forKey: queryId)
        }
        lock.unlock()

        if shouldNotify {
            terminal?(queryId)
        }
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
        archivedId: String?,
        targetWindowIncludesAnchor: Bool = false
    ) -> ChatAnchorContextPrefetchPlan {
        plan(
            coverage: ChatAnchorContextCoverage(
                olderLocalCount: max(0, observerIndex),
                newerLocalCount: max(0, totalCount - observerIndex - 1),
                olderBoundary: .unknown,
                newerBoundary: .unknown
            ),
            pageSize: pageSize,
            archivedId: archivedId,
            targetWindowIncludesAnchor: targetWindowIncludesAnchor
        )
    }

    static func plan(
        coverage: ChatAnchorContextCoverage,
        pageSize: Int,
        archivedId: String?,
        targetWindowIncludesAnchor: Bool = false
    ) -> ChatAnchorContextPrefetchPlan {
        guard let archivedId,
              archivedId.isNotEmpty else {
            return ChatAnchorContextPrefetchPlan(newerPageSize: nil, olderPageSize: nil)
        }

        let boundedPageSize = max(1, pageSize)
        let totalContextBudget = targetWindowIncludesAnchor
            ? max(0, boundedPageSize - 1)
            : boundedPageSize
        var olderTarget = targetWindowIncludesAnchor
            ? (totalContextBudget + 1) / 2
            : max(1, boundedPageSize / 2)
        var newerTarget = targetWindowIncludesAnchor
            ? totalContextBudget / 2
            : max(1, boundedPageSize / 2)

        // When one archive edge is authoritative, use its unavailable share
        // on the other side. This keeps the initial resident target window
        // bounded to `pageSize` while admitting as much truthful context as
        // the server can provide.
        if targetWindowIncludesAnchor,
           coverage.olderBoundary == .complete,
           coverage.olderLocalCount < olderTarget {
            newerTarget += olderTarget - coverage.olderLocalCount
            olderTarget = coverage.olderLocalCount
        }
        if targetWindowIncludesAnchor,
           coverage.newerBoundary == .complete,
           coverage.newerLocalCount < newerTarget {
            olderTarget += newerTarget - coverage.newerLocalCount
            newerTarget = coverage.newerLocalCount
        }

        let newerDeficit = coverage.newerLocalCount < newerTarget &&
            coverage.newerBoundary != .complete
            ? min(newerTarget - coverage.newerLocalCount, totalContextBudget)
            : 0
        let olderDeficit = coverage.olderLocalCount < olderTarget &&
            coverage.olderBoundary != .complete
            ? min(olderTarget - coverage.olderLocalCount, totalContextBudget)
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
        residentArchivedIds: [String?] = [],
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

        var olderLocalCount = max(0, observerIndex)
        var newerLocalCount = max(0, totalCount - observerIndex - 1)
        if residentArchivedIds.isNotEmpty,
           residentArchivedIds.indices.contains(observerIndex) {
            if let nearestOlderGap = nearestOlderGap(
                to: targetArchivedId,
                in: archiveState.knownGaps
            ),
               let firstContiguousIndex = residentArchivedIds.indices.first(where: { index in
                   guard index <= observerIndex,
                         let archivedId = residentArchivedIds[index] else {
                       return false
                   }
                   return isAtOrNewer(archivedId, than: nearestOlderGap.newerRangeOldestArchiveId)
               }) {
                olderLocalCount = max(0, observerIndex - firstContiguousIndex)
            }

            if let nearestNewerGap = nearestNewerGap(
                to: targetArchivedId,
                in: archiveState.knownGaps
            ),
               let lastContiguousIndex = residentArchivedIds.indices.last(where: { index in
                   guard index >= observerIndex,
                         let archivedId = residentArchivedIds[index] else {
                       return false
                   }
                   return isAtOrOlder(archivedId, than: nearestNewerGap.olderRangeNewestArchiveId)
               }) {
                newerLocalCount = max(0, lastContiguousIndex - observerIndex)
            }
        }

        return ChatAnchorContextCoverage(
            olderLocalCount: olderLocalCount,
            newerLocalCount: newerLocalCount,
            olderBoundary: hasKnownOlderGap
                ? .knownGap
                : (archiveState.fullArchiveLoaded ? .complete : .unknown),
            newerBoundary: hasKnownNewerGap
                ? .knownGap
                : (archiveState.newerLiveEdgeReached ? .complete : .unknown)
        )
    }

    private static func nearestOlderGap(
        to targetArchivedId: String,
        in knownGaps: [RegularChatArchiveGap]
    ) -> RegularChatArchiveGap? {
        knownGaps
            .filter { isAtOrOlder($0.newerRangeOldestArchiveId, than: targetArchivedId) }
            .max {
                compareArchiveIds($0.newerRangeOldestArchiveId, $1.newerRangeOldestArchiveId)
                    == .orderedAscending
            }
    }

    private static func nearestNewerGap(
        to targetArchivedId: String,
        in knownGaps: [RegularChatArchiveGap]
    ) -> RegularChatArchiveGap? {
        knownGaps
            .filter { isAtOrNewer($0.olderRangeNewestArchiveId, than: targetArchivedId) }
            .min {
                compareArchiveIds($0.olderRangeNewestArchiveId, $1.olderRangeNewestArchiveId)
                    == .orderedAscending
            }
    }

    private static func isAtOrNewer(_ lhs: String, than rhs: String) -> Bool {
        guard let comparison = compareArchiveIds(lhs, rhs) else {
            return lhs >= rhs
        }
        return comparison != .orderedAscending
    }

    private static func isAtOrOlder(_ lhs: String, than rhs: String) -> Bool {
        guard let comparison = compareArchiveIds(lhs, rhs) else {
            return lhs <= rhs
        }
        return comparison != .orderedDescending
    }

    static func completionAction(
        pendingQueryIds: Set<String>,
        totalPersistedMessageCount: Int,
        hasMaterializedExpectedContext: Bool = true
    ) -> ChatAnchorContextPrefetchCompletionAction {
        guard pendingQueryIds.isEmpty else {
            return .waitForMoreQueries
        }
        _ = totalPersistedMessageCount
        return hasMaterializedExpectedContext
            ? .complete
            : .waitForObserverSync
    }

    static func resumeAction(
        pendingQueryIds: Set<String>,
        totalPersistedMessageCount: Int,
        areMessagePipelinesIdle: Bool,
        didObservePostIdleTick: Bool,
        hasMaterializedExpectedContext: Bool = true
    ) -> ChatAnchorContextPrefetchResumeAction {
        guard pendingQueryIds.isEmpty else {
            return .waitForOutstandingQueries
        }
        _ = areMessagePipelinesIdle
        _ = didObservePostIdleTick
        if totalPersistedMessageCount > 0,
           !hasMaterializedExpectedContext {
            return .waitForPendingMessagePersistence
        }
        return hasMaterializedExpectedContext
            ? .readyToPosition
            : .waitForObserverSettle
    }
}

enum ChatAnchorContextCoverageResolver {
    static func coverage(
        observerIndex: Int?,
        residentArchivedIds: [String?],
        targetArchivedId: String,
        archiveState: ChatArchiveStateSnapshot
    ) -> ChatAnchorContextCoverage {
        guard let observerIndex,
              residentArchivedIds.indices.contains(observerIndex) else {
            return ChatAnchorContextPrefetchPolicy.coverage(
                observerIndex: 0,
                totalCount: 1,
                targetArchivedId: targetArchivedId,
                residentArchivedIds: [targetArchivedId],
                archiveState: archiveState
            )
        }

        return ChatAnchorContextPrefetchPolicy.coverage(
            observerIndex: observerIndex,
            totalCount: residentArchivedIds.count,
            targetArchivedId: targetArchivedId,
            residentArchivedIds: residentArchivedIds,
            archiveState: archiveState
        )
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

        if source == .initialUnreadBoundary ||
            source == .search ||
            source == .pushNotification ||
            source == .mentionNotification {
            return !(messageCount > 0 && hasLocalAnchor)
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
        source == .savedVisiblePosition ||
            source == .initialUnreadBoundary ||
            source == .search ||
            source == .pushNotification ||
            source == .mentionNotification
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

enum ChatAnchorBootstrapTransitionPolicy {
    static func usesBootstrapLoading(
        isShowingBootstrapPlaceholder: Bool,
        wouldOtherwiseBlockForAnchor: Bool
    ) -> Bool {
        isShowingBootstrapPlaceholder || wouldOtherwiseBlockForAnchor
    }
}

struct ChatAnchorDatasourceApplyPlan {
    let mode: ChatDatasourceApplyMode
    let invalidateLayout: Bool
}

enum ChatAnchorDatasourceApplyPolicy {
    static func plan(for source: ChatOpenMessageRequestSource) -> ChatAnchorDatasourceApplyPlan {
        if source == .search ||
            source == .pushNotification ||
            source == .mentionNotification {
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
    var remoteFetchSnapshotGenerationAtStart: UInt64? = nil
    var isRemoteFetchInFlight: Bool = false
    var isWaitingForObserverSync: Bool = false
    var persistenceMaterializedWindowGeneration: UInt64? = nil
    var persistenceSearchResolutionProof:
        ChatTimelineSearchResolutionProof = .notRequested
    var isPersistenceMaterializationInFlight: Bool = false
    var contextPrefetchAnchorKey: String? = nil
    var contextPrefetchQueryIds: Set<String> = []
    var contextPrefetchPendingQueryIds: Set<String> = []
    var contextPrefetchExpectedMessageCount: Int = 0
    var contextPrefetchPersistedMessageCount: Int = 0
    var contextPrefetchSnapshotGenerationAtStart: UInt64? = nil
    var contextPrefetchRequiredOlderLocalCount: Int = 0
    var contextPrefetchRequiredNewerLocalCount: Int = 0
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

enum ChatAnchorRemoteObserverBarrierPolicy {
    static func shouldWaitForNewerSnapshot(
        persistedMessageCount: Int,
        baselineGeneration: UInt64?,
        observedGeneration: UInt64
    ) -> Bool {
        guard persistedMessageCount > 0,
              let baselineGeneration else {
            return false
        }
        return observedGeneration <= baselineGeneration
    }
}

enum ChatPersistenceMaterializedSearchPhaseBAdmission: Equatable {
    case admitted(primary: String)
    case failed(ChatAnchorTransactionFailure)
}

enum ChatPersistenceMaterializedSearchTargetPolicy {
    static func hasBoundResolutionProof(
        request: ChatOpenMessageRequest,
        executionState: ChatAnchorExecutionState?
    ) -> Bool {
        guard request.source == .search,
              let executionState,
              executionState.request == request else {
            return false
        }
        if case .notRequested =
            executionState.persistenceSearchResolutionProof {
            return false
        }
        return true
    }

    static func boundResolutionFailure(
        request: ChatOpenMessageRequest,
        executionState: ChatAnchorExecutionState?,
        snapshot: ChatTimelineSessionSnapshot
    ) -> ChatAnchorTransactionFailure? {
        guard request.source == .search,
              let executionState,
              executionState.request == request else {
            return nil
        }
        switch executionState.persistenceSearchResolutionProof {
        case .failed(let failure):
            return failure
        case .found(let primary):
            guard let proofGeneration = executionState
                    .persistenceMaterializedWindowGeneration,
                  proofGeneration <= snapshot.generation,
                  let target = snapshot.item(primary: primary) else {
                return .targetMissing
            }
            return target.isDeleted ? .targetDeleted : nil
        case .notRequested:
            return nil
        }
    }

    static func phaseBAdmission(
        request: ChatOpenMessageRequest,
        executionState: ChatAnchorExecutionState?,
        snapshot: ChatTimelineSessionSnapshot
    ) -> ChatPersistenceMaterializedSearchPhaseBAdmission {
        guard request.source == .search,
              let executionState,
              executionState.request == request,
              let proofGeneration = executionState
                .persistenceMaterializedWindowGeneration,
              proofGeneration <= snapshot.generation else {
            return .failed(.targetMissing)
        }
        switch executionState.persistenceSearchResolutionProof {
        case .found(let primary):
            guard primary.isNotEmpty,
                  let target = snapshot.item(primary: primary) else {
                return .failed(.targetMissing)
            }
            guard !target.isDeleted else {
                return .failed(.targetDeleted)
            }
            return .admitted(primary: primary)
        case .failed(let failure):
            return .failed(failure)
        case .notRequested:
            return .failed(.targetMissing)
        }
    }

    static func resolvedMessage(
        request: ChatOpenMessageRequest,
        executionState: ChatAnchorExecutionState?,
        snapshot: ChatTimelineSessionSnapshot
    ) -> MessageStorageItem? {
        guard request.source == .search,
              let executionState,
              executionState.request == request,
              let proofGeneration = executionState
                .persistenceMaterializedWindowGeneration,
              proofGeneration <= snapshot.generation,
              case .found(let primary) = executionState
                .persistenceSearchResolutionProof,
              let message = snapshot.item(primary: primary),
              !message.isDeleted else {
            return nil
        }
        return message
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
        if state.isPositioning ||
            state.isRemoteFetchInFlight ||
            state.isPersistenceMaterializationInFlight {
            return .none
        }

        if state.isWaitingForObserverSync {
            return .waitForObserverSync
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
        hasObservedNewerSnapshot: Bool,
        pageSize: Int
    ) -> ChatAnchorExecutionAction {
        if persistedMessageCount > 0,
           !hasObservedNewerSnapshot {
            return .waitForObserverSync
        }

        if hasLocalMatch {
            return .resolveLocally
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

        for (queryID, manager) in searchArchiveManagersByQueryId {
            manager.cancelSearch(queryId: queryID)
            unregisterRemoteHistoryPersistenceSource(queryId: queryID)
        }
        searchArchiveManagersByQueryId.removeAll()
        searchSessionGenerationByQueryId.removeAll()
        _ = searchLocalProvider.cancelAll()

        _ = searchCalendarCompletionCoordinator?.cancel()
        searchCalendarCompletionCoordinator = nil
        searchCalendarTimestampMAMTransport = nil
        pendingSearchCalendarCompletionRequest = nil
        activeSearchCalendarCompletionRequest = nil
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
            applyLegacySearchPanelStateFromPresentation()
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
                suppressDefaultBottomScroll: true
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
        _ = searchNavigationFeedbackCoordinator.commitPositioned(
            index: index,
            generation: searchPresentationState.generation
        )
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
        guard request.source == .search else {
            return false
        }

        guard self.indexPathForLoadedMessage(request: request) != nil else {
            return true
        }

        return ChatAnchorContextPrefetchModePolicy.mode(
            for: request.source,
            hasLocalMatch: true,
            isSynced: self.currentChatIsSyncedForAnchorBootstrap(),
            hasCommittedInitialContent: self.initialFirstContentApplyCount > 0
        ) == .blocking
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

    private func requestOlderSearchResultsIfAvailable() {
        let generation = searchOlderPageNavigationGate.generation
        guard let request = searchOlderPageNavigationGate.requestNavigation(generation: generation),
              let queryId = currentSearchQueryId else {
            searchOlderPageNavigationGate.markTerminal(generation: generation)
            renderSearchNavigationButtons(animated: true)
            return
        }
        let didStartPage: Bool
        if let manager = searchArchiveManagersByQueryId[queryId] {
            didStartPage = manager.requestPendingSearchContinuation(queryId: queryId)
        } else {
            didStartPage = searchLocalProvider.requestNextPage(
                queryId: queryId,
                generation: generation
            )
        }
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

    /// The stacked fallback may finish UIKit presentation while the typed
    /// initial frame still owns the same exact request. Collapse every such
    /// callback into the existing terminal replay latch; a successful commit
    /// consumes the request before replay, while a blocked/failed terminal
    /// releases one generic attempt.
    @discardableResult
    private func retainPendingRequestForInitialFrameTerminalIfOwned(
        _ request: ChatOpenMessageRequest,
        hooks: ChatAnchorExecutionHooks? = nil
    ) -> Bool {
        guard self.pendingOpenMessageRequest == request,
              ChatInitialFramePendingRequestOwnershipPolicy
                .isOwnedByInitialFrame(
                    request: request,
                    phase: self.initialLocalFirstFramePhase
                ) else {
            return false
        }
        self.initialLocalFirstFrameShouldPerformPendingRequest = true
        self.activeAnchorExecutionHooks = hooks ?? self.activeAnchorExecutionHooks
        self.syncAnchorExecutionFlags()
        return true
    }

    internal func queueOpenMessageRequest(
        _ request: ChatOpenMessageRequest,
        hooks: ChatAnchorExecutionHooks? = nil
    ) {
        let honorsMessageAnchor = ChatOpenMessageRequestHandlingPolicy
            .shouldHonorMessageAnchorRequest(source: request.source)

        self.invalidateRetiredInitialFrameEffectsIfSuperseded(by: request)

        if self.deferReplacementDuringAtomicInitialFrameIfNeeded(
            request,
            hooks: hooks
        ) {
            return
        }
        if self.deferUnacknowledgedCommittedInitialFrameReplacementIfNeeded(
            request,
            hooks: hooks
        ) {
            return
        }
        self.revokeAcknowledgedCommittedInitialFrameIfSuperseded(by: request)
        self.discardScheduledDeferredInitialFrameReplacementForSequentialIntentIfPossible()

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
        if self.retainPendingRequestForInitialFrameTerminalIfOwned(
            request,
            hooks: hooks
        ) {
            return
        }
        if self.pendingOpenMessageRequest != request {
            // A true replacement either retargets the typed initial frame
            // below or starts its own generic execution. It must not inherit
            // a replay latched for the superseded request.
            self.initialLocalFirstFrameShouldPerformPendingRequest = false
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
            ConnectionDiagnosticsLogger.log(
                event: "chat_anchor_first_frame_retarget_requested",
                stream: .primary,
                jid: nil,
                details: [
                    "source": request.source.rawValue,
                    "hadPriorContentApply": self.initialFirstContentApplyCount > 0,
                    "showsSkeleton": self.showSkeletonObserver.value
                ]
            )
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
        if let executionState = self.activeAnchorExecutionState,
           executionState.request == request,
           executionState.contextPrefetchPendingQueryIds.isNotEmpty {
            self.pendingOpenMessageRequest = request
            self.activeAnchorExecutionHooks = hooks ?? self.activeAnchorExecutionHooks
            self.syncAnchorExecutionFlags()
            return
        }
        if request.source == .search {
            self.markSearchResultNavigationLoadingContext(for: request)
            self.setSearchResultsPanelContextLoading(true)
        }
        self.pendingOpenMessageRequest = request
        self.activeAnchorExecutionHooks = hooks
        self.syncAnchorExecutionFlags()
        if self.submitArchiveEngineTarget(request) {
            return
        }
        self.performPendingOpenMessageRequestIfNeeded(trigger: .manual)
    }

    /// Once A has fully left its terminal critical section, an independently
    /// delivered intent C wins over the deferred B whose identity-bound replay
    /// is merely waiting on the next main turn. This disposition must precede
    /// the honored/suppressed split so force-latest C cannot leave B armed.
    private func discardScheduledDeferredInitialFrameReplacementForSequentialIntentIfPossible() {
        guard self.initialLocalFirstFrameTerminalizingAttempt == nil,
              self.deferredInitialLocalFirstFrameReplacement != nil else {
            return
        }
        self.deferredInitialLocalFirstFrameReplacement = nil
    }

    private func invalidateRetiredInitialFrameEffectsIfSuperseded(
        by request: ChatOpenMessageRequest
    ) {
        guard self.initialLocalFirstFramePresentationOwnership == nil,
              case .committed(let descriptor) =
                self.initialLocalFirstFramePhase,
              descriptor.request != request else {
            return
        }
        if let token = self.initialLocalFirstFrameLatestEffectToken {
            self.readVisiblePresentationCoordinator.revoke(
                initialFrameEffectToken: token
            )
        }
        self.initialLocalFirstFrameLatestEffectToken = nil
        self.initialLocalFirstFramePresentationGeneration &+= 1
        self.initialLocalFirstFramePhase = .idle
    }

    private func deferReplacementDuringAtomicInitialFrameIfNeeded(
        _ request: ChatOpenMessageRequest,
        hooks: ChatAnchorExecutionHooks?
    ) -> Bool {
        if let terminalizingAttempt =
                self.initialLocalFirstFrameTerminalizingAttempt,
           self.initialLocalFirstFramePresentationOwnership?.attempt ===
                terminalizingAttempt {
            if terminalizingAttempt.descriptor.request == request {
                if self.deferredInitialLocalFirstFrameReplacement == nil,
                   let hooks {
                    self.activeAnchorExecutionHooks = hooks
                }
                return true
            }
            self.deferredInitialLocalFirstFrameReplacement =
                ChatDeferredInitialFrameReplacement(
                    supersededAttempt: terminalizingAttempt,
                    request: request,
                    hooks: hooks
                )
            self.initialLocalFirstFrameShouldPerformPendingRequest = false
            return true
        }
        guard case .presenting(let descriptor) =
                self.initialLocalFirstFramePhase else {
            return false
        }
        if descriptor.request == request {
            if self.deferredInitialLocalFirstFrameReplacement == nil {
                _ = self.retainPendingRequestForInitialFrameTerminalIfOwned(
                    request,
                    hooks: hooks
                )
            }
            return true
        }
        if let deferred = self.deferredInitialLocalFirstFrameReplacement {
            self.deferredInitialLocalFirstFrameReplacement =
                ChatDeferredInitialFrameReplacement(
                    supersededAttempt: deferred.supersededAttempt,
                    request: request,
                    hooks: hooks
                )
            return true
        }
        guard let ownership =
                self.initialLocalFirstFramePresentationOwnership,
              ownership.phase == .presenting,
              ownership.attempt.descriptor == descriptor else {
            return false
        }
        let attempt = ownership.attempt
        self.deferredInitialLocalFirstFrameReplacement =
            ChatDeferredInitialFrameReplacement(
                supersededAttempt: attempt,
                request: request,
                hooks: hooks
            )
        self.initialLocalFirstFrameShouldPerformPendingRequest = false
        self.revokeInitialFramePresentationAttempt(attempt)
        return true
    }

    private func deferUnacknowledgedCommittedInitialFrameReplacementIfNeeded(
        _ request: ChatOpenMessageRequest,
        hooks: ChatAnchorExecutionHooks?
    ) -> Bool {
        guard let ownership = self.initialLocalFirstFramePresentationOwnership,
              ownership.phase == .committed,
              ownership.attempt.descriptor.request != request,
              self.initialLocalFirstFrameCoreAnimationReceiptGeneration !=
                ownership.attempt.presentationGeneration else {
            return false
        }
        let attempt = ownership.attempt
        let initialReplacement = ChatDeferredInitialFrameReplacement(
            supersededAttempt: attempt,
            request: request,
            hooks: hooks
        )
        self.deferredInitialLocalFirstFrameReplacement = initialReplacement
        self.initialLocalFirstFrameShouldPerformPendingRequest = false
        guard self.rollbackUnacknowledgedInitialFramePresentation(attempt) else {
            if self.deferredInitialLocalFirstFrameReplacement ===
                initialReplacement {
                self.deferredInitialLocalFirstFrameReplacement = nil
            }
            return false
        }
        self.revokeInitialFramePresentationAttempt(attempt)
        self.resolveSupersededInitialFramePresentationAttempt(attempt)
        return true
    }

    private func revokeAcknowledgedCommittedInitialFrameIfSuperseded(
        by request: ChatOpenMessageRequest
    ) {
        guard let ownership = self.initialLocalFirstFramePresentationOwnership,
              ownership.phase == .committed,
              ownership.attempt.descriptor.request != request else {
            return
        }
        let attempt = ownership.attempt
        self.revokeInitialFramePresentationAttempt(attempt)
        if self.initialLocalFirstFramePhase ==
            .committed(attempt.descriptor) {
            self.initialLocalFirstFramePhase = .idle
        }
    }

    private var shouldRetargetPendingInitialFirstFrame: Bool {
        guard self.isViewLoaded,
              self.timelineSession != nil else {
            return false
        }
        return !self.datasource.contains { !$0.isFakeMessage }
    }

    private func handleSuppressedOpenMessageRequest(animated: Bool) {
        self.requestForceLatestOpen(animated: animated)
        self.finishInitialFramePreparationAfterSuppressedOpenRequest()
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
        let hadOutstandingContextWork = executionState.contextPrefetchPendingQueryIds.isNotEmpty
        let activeHooks = hooks ?? self.activeAnchorExecutionHooks
        self.activeAnchorExecutionHooks = activeHooks
        let usesTransientHighlight = request.source.usesTransientHighlight && request.highlight
        let contextPrefetchMode = ChatAnchorContextPrefetchModePolicy.mode(
            for: request.source,
            hasLocalMatch: true,
            isSynced: self.currentChatIsSyncedForAnchorBootstrap(),
            hasCommittedInitialContent: self.initialFirstContentApplyCount > 0
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

        if contextPrefetchMode == .background,
           !hadOutstandingContextWork,
           ChatAnchorContextPrefetchDispatchPolicy.phase(for: contextPrefetchMode) == .beforePositioning {
            self.startBackgroundContextPrefetchIfNeeded(
                around: resolvedTarget,
                request: request
            )
        }

        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(true)
        self.timelineInteractionState.unlock()

        self.notifyAnchorPositioningStarted(token: transactionToken)
        if request.source == .search {
            self.setSearchResultsPanelContextLoading(false)
        }
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
        return request.anchor.messagePrimary.flatMap {
            snapshot.residentIndex.index(primary: $0)
        } ?? RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
            request.anchor.archivedId
        ).flatMap {
            snapshot.residentIndex.index(archivedId: $0)
        } ?? request.anchor.messageId.flatMap {
            snapshot.residentIndex.index(messageId: $0)
        }
    }

    /// Installs the exact anchor transaction without invoking callback-capable
    /// UI or test hooks. Initial-frame presentation ownership must be created
    /// from this token before activation is allowed to reenter request routing.
    @discardableResult
    internal func prepareLocalFirstFrameAnchorExecution(
        request: ChatOpenMessageRequest
    ) -> ChatAnchorTransactionToken {
        var executionState: ChatAnchorExecutionState
        if let active = self.activeAnchorExecutionState,
           active.request == request,
           self.anchorTransactionGate.snapshot.activeToken ==
            active.transactionToken {
            executionState = active
            executionState.isPositioning = true
            executionState.isWaitingForObserverSync = false
        } else {
            executionState = ChatAnchorExecutionState(
                request: request,
                usesBootstrapLoading: false
            )
            executionState.isPositioning = true
            _ = self.anchorTransactionGate.begin(
                token: executionState.transactionToken,
                requestIdentity: self.anchorRequestIdentity(request)
            )
        }
        self.activeAnchorExecutionState = executionState
        return executionState.transactionToken
    }

    internal func activatePreparedLocalFirstFrameAnchor(
        request: ChatOpenMessageRequest,
        transactionToken: ChatAnchorTransactionToken
    ) {
        guard let executionState = self.activeAnchorExecutionState,
              executionState.request == request,
              executionState.transactionToken == transactionToken,
              self.anchorTransactionGate.snapshot.activeToken ==
                transactionToken else {
            return
        }
        self.isApplyingBootstrapAnchorWindow = true
        self.syncAnchorExecutionFlags()
        self.setLoadingIndicatorVisible(false)
        self.setArchiveLoading(false)
        self.setDatasourceLoadingEnabled(false)
        self.notifyAnchorPositioningStarted(token: transactionToken)
    }

    internal func beginPreparedLocalFirstFrameAnchor(
        request: ChatOpenMessageRequest
    ) {
        let token = self.prepareLocalFirstFrameAnchorExecution(request: request)
        self.activatePreparedLocalFirstFrameAnchor(
            request: request,
            transactionToken: token
        )
    }

    internal func finishPreparedLocalFirstFrameAnchor(
        request: ChatOpenMessageRequest,
        primary: String,
        archivedId: String?,
        transactionToken: ChatAnchorTransactionToken?,
        presentationAttempt: ChatInitialFramePresentationAttempt
    ) {
        guard let transactionToken,
              self.isInitialFramePresentationAttemptSemanticallyCurrent(
                presentationAttempt
              ),
              presentationAttempt.anchorTransactionToken == transactionToken,
              let executionState = self.activeAnchorExecutionState,
              executionState.request == request,
              executionState.transactionToken == transactionToken,
              self.anchorTransactionGate.snapshot.activeToken ==
                transactionToken else {
            return
        }
        if request.highlight {
            self.applyTransientMessageHighlight(
                primary: primary,
                initialFrameEffectToken: presentationAttempt.effectToken
            )
        }
        guard self.isInitialFramePresentationAttemptSemanticallyCurrent(
            presentationAttempt
        ) else {
            return
        }
        self.scheduleMentionReadOnVisibleIfNeeded(
            for: request,
            positionedPrimary: primary,
            presentationAttempt: presentationAttempt
        )
        guard self.isInitialFramePresentationAttemptSemanticallyCurrent(
            presentationAttempt
        ) else {
            return
        }
        let contextPrefetchMode = ChatAnchorContextPrefetchModePolicy.mode(
            for: request.source,
            hasLocalMatch: true,
            isSynced: self.currentChatIsSyncedForAnchorBootstrap(),
            hasCommittedInitialContent: self.initialFirstContentApplyCount > 0
        )
        if contextPrefetchMode == .background,
           ChatAnchorContextPrefetchDispatchPolicy.phase(for: contextPrefetchMode) == .beforePositioning {
            self.startBackgroundContextPrefetchIfNeeded(
                around: ResolvedJumpTarget(primary: primary, archivedId: archivedId),
                request: request
            )
        }
        guard self.isInitialFramePresentationAttemptSemanticallyCurrent(
            presentationAttempt
        ) else {
            return
        }
        ConnectionDiagnosticsLogger.log(
            event: "chat_anchor_local_first_frame_positioned",
            stream: .primary,
            jid: nil,
            details: [
                "source": request.source.rawValue,
                "residentAtLiveTail": self.virtualTimelineState.isResidentAtLiveTail,
                "realMessageCount": self.datasource.lazy.filter { !$0.isFakeMessage }.count
            ]
        )
        self.finishActiveAnchorExecution(token: transactionToken)
    }

    internal func rollbackPreparedLocalFirstFrameAnchor(
        request: ChatOpenMessageRequest,
        transactionToken: ChatAnchorTransactionToken?
    ) {
        guard let transactionToken,
              let executionState = self.activeAnchorExecutionState,
              executionState.request == request,
              executionState.transactionToken == transactionToken else {
            return
        }
        self.cancelActiveAnchorExecution(
            token: transactionToken,
            failure: .targetMissing,
            invokeFailureHook: false,
            preservesViewportPresentation: true
        )
        // The visual transaction failed, not the user's navigation intent.
        // Keep the request available for the next generation-scoped attempt.
        self.pendingOpenMessageRequest = request
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

        let wouldOtherwiseBlockForAnchor = ChatInitialAnchorBootstrapPolicy.shouldBlockBootstrap(
            source: request.source,
            isSynced: self.currentChatIsSyncedForAnchorBootstrap(),
            messageCount: self.localHistoryMessageCountForBootstrap(),
            hasLocalAnchor: hasLocalAnchor,
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
        )
        return ChatAnchorBootstrapTransitionPolicy.usesBootstrapLoading(
            isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder,
            wouldOtherwiseBlockForAnchor: wouldOtherwiseBlockForAnchor
        )
    }

    private func currentChatIsSyncedForAnchorBootstrap() -> Bool {
        self.currentInitialFrameReadinessProof()?.isSynced ?? false
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
        if case .search = executionState.request.source {
            self.postChatSearchAccessibilityAnnouncement(
                .positioningFailure,
                generation: self.searchPresentationState.generation
            )
        }
        self.view.makeToast("Original message is no longer available")
    }

    /// Bridges the typed initial-frame semantic failure back into the anchor
    /// transaction without exposing the general failure primitive outside
    /// this extension. Returning false lets Dataset publish its non-anchor
    /// terminal presentation when no matching transaction is active.
    @discardableResult
    internal func failActiveAnchorExecutionFromInitialFrame(
        request: ChatOpenMessageRequest,
        failure: ChatAnchorTransactionFailure
    ) -> Bool {
        guard let executionState = self.activeAnchorExecutionState,
              executionState.request == request,
              self.anchorTransactionGate.snapshot.activeToken ==
                executionState.transactionToken else {
            return false
        }
        self.failActiveAnchorExecution(
            token: executionState.transactionToken,
            failure: failure
        )
        return true
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
        let onFailed = invokeFailureHook ? self.activeAnchorExecutionHooks?.onFailed : nil
        self.cleanupAnchorExecutionResources(executionState)
        self.clearAnchorExecutionPresentationState(
            preservesViewportPresentation: preservesViewportPresentation
        )
        onFailed?()
    }

    private func cleanupAnchorExecutionResources(_ executionState: ChatAnchorExecutionState) {
        self.revokeActiveAnchorPersistenceMaterializationAdmission()
        var queryIds = executionState.contextPrefetchQueryIds
        if let remoteQueryId = executionState.remoteQueryId {
            queryIds.insert(remoteQueryId)
        }
        for (queryId, token) in self.anchorTransactionTokenByQueryId
            where token == executionState.transactionToken {
            queryIds.insert(queryId)
        }
        queryIds.forEach { queryId in
            self.anchorTransactionTimeoutWorkItems.removeValue(forKey: queryId)?.cancel()
            self.anchorTransactionTokenByQueryId.removeValue(forKey: queryId)
            self.abortedRemoteHistoryQueryIds.insert(queryId)
            self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)
        }
    }

    private func clearAnchorExecutionPresentationState(
        preservesViewportPresentation: Bool = false
    ) {
        self.pendingOpenMessageRequest = nil
        self.activeAnchorExecutionState = nil
        self.activeAnchorExecutionHooks = nil
        self.isApplyingBootstrapAnchorWindow = false
        self.syncAnchorExecutionFlags()
        self.setSearchAnchorNavigationScrollLocked(false)
        guard !preservesViewportPresentation else {
            return
        }
        self.setLoadingIndicatorVisible(false)
        self.setDatasourceLoadingEnabled(true)
        self.setSearchResultsPanelContextLoading(false)
        self.scheduleReadVisibleStableLayoutRetryIfNeeded()
    }

    @discardableResult
    private func startRemoteAnchorFetch(
        plan: ChatAnchorRemoteFetchPlan,
        for request: ChatOpenMessageRequest
    ) -> String? {
        if self.submitArchiveEngineTarget(request) {
            return self.archiveWindowIntent?.id.uuidString
        }
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
        state.remoteFetchSnapshotGenerationAtStart =
            self.timelineSession?.snapshot.generation
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

        let regularRequestPlan: MessageArchiveManager.RegularChatArchiveRequestPlan?
        guard self.conversationType == .regular else {
            regularRequestPlan = nil
            self.performArchiveAction(
                queryIds: [queryId],
                transactionToken: transactionToken,
                requestSource: request.source,
                transportOwnership: .anchorTarget,
                { stream, mam in
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
                },
                unavailable: {
                    self.failActiveAnchorExecution(
                        token: transactionToken,
                        failure: .disconnected
                    )
                }
            )
            return queryId
        }
        switch plan {
        case .exactArchivedId(let archivedId):
            regularRequestPlan = MessageArchiveManager
                .regularExactAnchorRequestPlan(
                    jid: self.jid,
                    archivedId: archivedId
                )
        case .dateWindow(let start, let end, let max):
            regularRequestPlan = MessageArchiveManager
                .regularDateWindowAnchorRequestPlan(
                    jid: self.jid,
                    start: start,
                    end: end,
                    max: max
                )
        }

        self.performArchiveAction(
            queryIds: [queryId],
            transactionToken: transactionToken,
            regularRequestPlansByQueryId: regularRequestPlan.map {
                [queryId: $0]
            } ?? [:],
            requestSource: request.source,
            transportOwnership: .anchorTarget,
            { stream, mam in
                guard let regularRequestPlan else { return }
                _ = mam.startRegularArchiveRequest(
                    stream,
                    plan: regularRequestPlan,
                    queryId: queryId,
                    flipPage: false,
                    joinDuplicateRequests: false,
                    callback: nil,
                    requestCallbacks: requestCallbacks
                )
            },
            unavailable: {
                self.failActiveAnchorExecution(
                    token: transactionToken,
                    failure: .disconnected
                )
            }
        )

        return queryId
    }

    private func performArchiveAction(
        queryIds: Set<String> = [],
        transactionToken: ChatAnchorTransactionToken? = nil,
        detachedPersistenceTransaction: ChatDetachedRemoteHistoryPersistenceTransaction? = nil,
        regularRequestPlansByQueryId:
            [String: MessageArchiveManager.RegularChatArchiveRequestPlan] = [:],
        requestSource: ChatOpenMessageRequestSource? = nil,
        transportOwnership: ChatRemoteArchiveTransportOwnership =
            .detachedBackground,
        _ action: @escaping (XMPPStream, MessageArchiveManager) -> Void,
        unavailable: (() -> Void)? = nil
    ) {
        if let transactionToken,
           self.anchorTransactionGate.snapshot.activeToken != transactionToken {
            return
        }
        if detachedPersistenceTransaction == nil {
            queryIds.forEach {
                self.registerRemoteHistoryEndPageDispatcher(queryId: $0)
                self.registerRemoteHistoryFailureDispatcher(queryId: $0)
            }
        }
#if DEBUG || CHAT_PERFORMANCE_LAB
        let descriptorContext: (
            leasePurpose: ChatPerformanceFixtureArchiveLeasePurpose,
            semanticRouteClass:
                ChatPerformanceFixtureArchiveSemanticRouteClass
        )
        switch transportOwnership {
        case .anchorTarget:
            descriptorContext = (.anchorTransaction, .exactTarget)
        case .anchorContext:
            descriptorContext = (.anchorTransaction, .anchorContext)
        case .detachedBackground:
            descriptorContext = (.detachedBackground, .backgroundContext)
        }
        let descriptorsByQueryId = regularRequestPlansByQueryId.reduce(
            into: [String: ChatPerformanceFixtureArchiveRequestDescriptor]()
        ) { descriptors, entry in
            descriptors[entry.key] =
                ChatPerformanceFixtureArchiveRequestDescriptor.make(
                    plan: entry.value,
                    leasePurpose: descriptorContext.leasePurpose,
                    requestSource: requestSource,
                    semanticRouteClass:
                        descriptorContext.semanticRouteClass
                )
        }
        let performanceFixtureTransportRequest =
            ChatPerformanceFixtureArchiveTransportRequest(
                kind: .detachedPage,
                queryIds: queryIds,
                descriptorsByQueryId: descriptorsByQueryId
            )
        if queryIds.isNotEmpty,
           let executor = self.performanceFixtureArchiveTransportExecutor,
           let session = self.performanceFixtureArchiveTransportProvider?(
               performanceFixtureTransportRequest
           ) {
            executor { [weak self] in
                guard let self else {
                    return
                }
                queryIds.forEach {
                    if let detachedPersistenceTransaction {
                        detachedPersistenceTransaction.registerPersistenceSource(
                            session.messageManager,
                            archiveManager: session.archiveManager,
                            queryId: $0
                        )
                    } else {
                        self.registerRemoteHistoryPersistenceSource(
                            session.messageManager,
                            archiveManager: session.archiveManager,
                            queryId: $0
                        )
                    }
                }
                action(session.stream, session.archiveManager)
                DispatchQueue.main.async {
                    self.performanceFixtureArchiveTransportDidStartHandler?(
                        performanceFixtureTransportRequest
                    )
                }
            }
            return
        }
#endif
        let fallback = {
            if let transactionToken,
               self.anchorTransactionGate.snapshot.activeToken != transactionToken {
                return
            }
            guard let account = AccountManager.shared.find(for: self.owner) else {
                if let detachedPersistenceTransaction {
                    detachedPersistenceTransaction.cancel()
                } else {
                    queryIds.forEach {
                        self.unregisterRemoteHistoryEndPageDispatcher(queryId: $0)
                        self.unregisterRemoteHistoryFailureDispatcher(queryId: $0)
                    }
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
                    if let detachedPersistenceTransaction {
                        detachedPersistenceTransaction.registerPersistenceSource(
                            user.messages,
                            archiveManager: user.mam,
                            queryId: $0
                        )
                    } else {
                        self.registerRemoteHistoryPersistenceSource(
                            user.messages,
                            archiveManager: user.mam,
                            queryId: $0
                        )
                    }
                }
                action(stream, user.mam)
            }
        }

        XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
            if let transactionToken,
               self.anchorTransactionGate.snapshot.activeToken != transactionToken {
                return
            }
            session.logConnectionDiagnostics(
                event: "ui_action_chat_archive_dispatch",
                details: [
                    "mamPresent": session.mam != nil,
                    "messagesPresent": session.messages != nil,
                    "registeredQueryCount": queryIds.count,
                    "transactionScoped": transactionToken != nil
                ]
            )
            if let mam = session.mam {
                queryIds.forEach {
                    if let detachedPersistenceTransaction {
                        detachedPersistenceTransaction.registerPersistenceSource(
                            session.messages,
                            archiveManager: mam,
                            queryId: $0
                        )
                    } else {
                        self.registerRemoteHistoryPersistenceSource(
                            session.messages,
                            archiveManager: mam,
                            queryId: $0
                        )
                    }
                }
                action(stream, mam)
                session.logConnectionDiagnostics(event: "ui_action_chat_archive_action_returned")
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
            if let message = ChatPersistenceMaterializedSearchTargetPolicy
                .resolvedMessage(
                    request: request,
                    executionState: self.activeAnchorExecutionState,
                    snapshot: snapshot
                ) {
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
            if ChatPersistenceMaterializedSearchTargetPolicy
                .hasBoundResolutionProof(
                    request: request,
                    executionState: self.activeAnchorExecutionState
                ) {
                // A Phase-A winner is immutable for this token. Missing or
                // deleted proved-primary state fails closed; never let a
                // stale main-thread Realm semantic lookup replace it.
                return nil
            }
            // Before Phase A binds an archive/message-id semantic proof, only
            // a globally unique resident primary is authoritative. A miss is
            // deliberately handed to the typed off-main preparation.
            guard let message = snapshot.item(
                primary: request.anchor.messagePrimary
            ) else {
                return nil
            }
            return (message, .primary)
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
        guard request.source == .search,
              let timelineSession = self.timelineSession else {
            return .targetMissing
        }
        if ChatPersistenceMaterializedSearchTargetPolicy
            .hasBoundResolutionProof(
                request: request,
                executionState: self.activeAnchorExecutionState
            ) {
            return ChatPersistenceMaterializedSearchTargetPolicy
                .boundResolutionFailure(
                    request: request,
                    executionState: self.activeAnchorExecutionState,
                    snapshot: timelineSession.snapshot
                ) ?? .targetMissing
        }
        return timelineSession
            .resolvedSearchMessageResolution(anchor: request.anchor)
            .failure ?? .targetMissing
    }

    internal func hasLocalAnchorForBootstrap(_ request: ChatOpenMessageRequest) -> Bool {
        guard ChatLocalFirstFrameRequestAdmissionPolicy.isStructurallyAdmissible(
            request: request,
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        ) else {
            return false
        }

        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        if case .blockedMissingTarget(let blockedDescriptor) =
            self.initialLocalFirstFramePhase,
           blockedDescriptor == descriptor {
            return false
        }

        if request.source == .savedVisiblePosition,
           let probedDecision = self.savedPositionFirstFrameProbedDecision(
               for: request
           ) {
            if case .savedPosition = probedDecision {
                return true
            }
            return false
        }
        return true
    }

    internal func savedPositionFirstFrameDecision(
        for request: ChatOpenMessageRequest
    ) -> ChatSavedPositionFirstFrameDecision {
        if let probedDecision = self.savedPositionFirstFrameProbedDecision(for: request) {
            return probedDecision
        }
        guard request.source == .savedVisiblePosition,
              ChatLocalFirstFrameRequestAdmissionPolicy.isStructurallyAdmissible(
                request: request,
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
              ),
              let residentSnapshot = self.timelineSession?.snapshot,
              let localAnchorIndex = self.savedPositionFirstFrameObserverIndex(
                for: request,
                residentSnapshot: residentSnapshot
              ) else {
            return .standardContent
        }

        let archiveCoverageContext = self.savedPositionFirstFrameArchiveCoverageContext(
            localAnchorIndex: localAnchorIndex,
            residentSnapshot: residentSnapshot,
            pageSize: self.initialFirstFramePageSize
        )
        return ChatSavedPositionFirstFramePolicy.decision(
            requestSource: request.source,
            // Synchronization/readiness is reduced by the bootstrap state.
            // This decision answers only whether the resident anchor window
            // is structurally safe to publish.
            isSynced: true,
            observerCount: residentSnapshot.items.count,
            localAnchorIndex: localAnchorIndex,
            pageSize: self.initialFirstFramePageSize,
            isPageUnlocked: true,
            archivedIdsByIndex: archiveCoverageContext.archivedIdsByIndex,
            knownGaps: archiveCoverageContext.knownGaps
        )
    }

    internal func shouldDeferInitialBootstrapArchiveForSavedPositionProbe(
        _ semanticTarget: MessageArchiveManager.ChatBootstrapPageTarget
    ) -> Bool {
        guard case .savedPosition = semanticTarget,
              let request = self.pendingOpenMessageRequest,
              request.source == .savedVisiblePosition,
              ChatLocalFirstFrameRequestAdmissionPolicy.isStructurallyAdmissible(
                request: request,
                owner: self.owner,
                jid: self.jid,
                conversationType: self.conversationType
              ) else {
            return false
        }
        let requestTarget = MessageArchiveManager.ChatBootstrapPageTarget.savedPosition(
            messagePrimary: request.anchor.messagePrimary,
            archivedId: request.anchor.archivedId,
            messageId: request.anchor.messageId,
            sourceDate: request.anchor.sourceDate
        )
        guard semanticTarget == requestTarget,
              self.savedPositionFirstFrameProbedDecision(for: request) == nil else {
            return false
        }
        if let residentSnapshot = self.timelineSession?.snapshot,
           self.savedPositionFirstFrameObserverIndex(
               for: request,
               residentSnapshot: residentSnapshot
           ) != nil {
            return false
        }
        guard case .preparing(let descriptor) = self.initialLocalFirstFramePhase else {
            return false
        }
        return descriptor.request == request
    }

    /// Generic exact-message routes are already owned by the anchor
    /// transaction. Letting the account-scoped bootstrap lease run as well
    /// would race its exact request with an unrelated newest-page request and
    /// make a target-only intermediate frame observable. This ownership starts
    /// before the first skeleton commit: stacked navigation can ask for archive
    /// work while its destination is still preparing and has no committed
    /// placeholder yet. Saved-position and unread-boundary routes retain their
    /// dedicated bootstrap precedence.
    internal func shouldDeferInitialBootstrapArchiveForAnchorTransaction(
        _ semanticTarget: MessageArchiveManager.ChatBootstrapPageTarget
    ) -> Bool {
        guard case .savedPosition = semanticTarget,
              let request = self.pendingOpenMessageRequest,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              request.source != .savedVisiblePosition,
              case .anchor = request.targetResolution,
              ChatOpenMessageRequestHandlingPolicy
                .shouldHonorMessageAnchorRequest(source: request.source),
              // Structural first-frame admission remains true during
              // `.preparing`; only the session lookup proves a resident target.
              self.localAnchorMessage(for: request) == nil else {
            return false
        }
        return true
    }

    internal func savedPositionFirstFrameProbedDecision(
        for request: ChatOpenMessageRequest
    ) -> ChatSavedPositionFirstFrameDecision? {
        guard let result = self.savedPositionFirstFrameProbeResult,
              result.request == request else {
            return nil
        }
        guard let currentKnownGaps = self.currentInitialFrameReadinessProof()?.knownGaps else {
            return result.decision
        }
        guard result.knownGaps == currentKnownGaps else {
            self.savedPositionFirstFrameProbeResult = nil
            return nil
        }
        return result.decision
    }

    private func savedPositionFirstFrameArchiveCoverageContext(
        localAnchorIndex: Int?,
        residentSnapshot: ChatTimelineSessionSnapshot?,
        pageSize: Int
    ) -> (
        archivedIdsByIndex: [Int: String],
        knownGaps: [RegularChatArchiveGap]
    ) {
        guard self.conversationType == .regular,
              let residentSnapshot else {
            return ([:], [])
        }

        let knownGaps = self.currentInitialFrameReadinessProof()?.knownGaps ?? []
        guard knownGaps.isNotEmpty else {
            return ([:], [])
        }

        guard let localAnchorIndex,
              localAnchorIndex >= 0 else {
            return ([:], knownGaps)
        }

        let window = ChatDatasetCoordinator(pageSize: pageSize)
            .replacementWindow(around: localAnchorIndex, totalCount: residentSnapshot.items.count)

        var archivedIdsByIndex: [Int: String] = [:]
        for index in window.minIndex..<window.maxIndex
            where residentSnapshot.items.indices.contains(index) {
            if let archiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                residentSnapshot.items[index].archivedId
            ) {
                archivedIdsByIndex[index] = archiveId
            }
        }

        return (archivedIdsByIndex, knownGaps)
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
        positionedPrimary: String,
        presentationAttempt: ChatInitialFramePresentationAttempt? = nil
    ) {
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.mentionReadOnVisibleSchedulingObserverForTests?(request)
#endif
        let initialFrameEffectToken = presentationAttempt?.effectToken
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            if let initialFrameEffectToken,
               !self.isLatestInitialFrameEffectToken(
                    initialFrameEffectToken
               ) {
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
                    positionedMessagePrimary: positionedPrimary,
                    initialFrameEffectToken: initialFrameEffectToken
                )
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
        state.contextPrefetchSnapshotGenerationAtStart = nil
        state.contextPrefetchRequiredOlderLocalCount = 0
        state.contextPrefetchRequiredNewerLocalCount = 0
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

    private func hasMaterializedExpectedContext(
        around target: ResolvedJumpTarget,
        request: ChatOpenMessageRequest,
        state: ChatAnchorExecutionState
    ) -> Bool {
        guard state.request == request,
              state.contextPrefetchAnchorKey ==
                self.contextPrefetchAnchorKey(for: target, request: request),
              let snapshot = self.timelineSession?.snapshot else {
            return false
        }
        let targetArchivedID = request.anchor.archivedId ?? target.archivedId
        let targetIndex = snapshot.residentIndex.index(primary: target.primary) ??
            targetArchivedID.flatMap {
                snapshot.residentIndex.index(archivedId: $0)
            }
        guard let targetIndex,
              snapshot.items.indices.contains(targetIndex),
              let targetArchivedID,
              targetArchivedID.isNotEmpty else {
            return false
        }
        let coverage = ChatAnchorContextCoverageResolver.coverage(
            observerIndex: targetIndex,
            residentArchivedIds: snapshot.items.map(\.archivedId),
            targetArchivedId: targetArchivedID,
            archiveState: self.loadChatArchiveStateSnapshot()
        )
        return ChatAnchorContextMaterializationPolicy.isReady(
            snapshotGeneration: snapshot.generation,
            baselineGeneration:
                state.contextPrefetchSnapshotGenerationAtStart,
            targetIsMaterialized: true,
            olderLocalCount: coverage.olderLocalCount,
            newerLocalCount: coverage.newerLocalCount,
            requiredOlderLocalCount:
                state.contextPrefetchRequiredOlderLocalCount,
            requiredNewerLocalCount:
                state.contextPrefetchRequiredNewerLocalCount,
            olderBoundary: coverage.olderBoundary,
            newerBoundary: coverage.newerBoundary,
            persistedMessageCount:
                state.contextPrefetchPersistedMessageCount
        )
    }

    private func prepareContextPrefetchIfNeeded(
        around target: ResolvedJumpTarget,
        request: ChatOpenMessageRequest
    ) -> Bool {
        // The archive engine's verified target window already owns the complete
        // 30/30 context. Starting the legacy context probes here would bypass
        // coverage admission and the single account MAM lane.
        guard !self.archiveEnginePresentationActive else {
            return false
        }
        guard var executionState = self.activeAnchorExecutionState else {
            return false
        }

        let anchorKey = self.contextPrefetchAnchorKey(for: target, request: request)

        if executionState.contextPrefetchAnchorKey == anchorKey {
            let hasMaterializedExpectedContext =
                self.hasMaterializedExpectedContext(
                    around: target,
                    request: request,
                    state: executionState
                )
            let action = ChatAnchorContextPrefetchPolicy.resumeAction(
                pendingQueryIds: executionState.contextPrefetchPendingQueryIds,
                totalPersistedMessageCount: executionState.contextPrefetchPersistedMessageCount,
                // A query leaves `contextPrefetchPendingQueryIds` only from the
                // post-persistence-barrier final callback.
                areMessagePipelinesIdle: executionState.contextPrefetchPendingQueryIds.isEmpty,
                didObservePostIdleTick: executionState.didObserveContextPostIdleTick,
                hasMaterializedExpectedContext:
                    hasMaterializedExpectedContext
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
                if executionState.contextPrefetchPersistedMessageCount == 0 {
                    self.scheduleContextPrefetchObserverResumeIfNeeded()
                }
                return true
            case .readyToPosition:
                self.activeAnchorExecutionState = executionState
                self.syncAnchorExecutionFlags()
                return false
            }
        }

        self.resetContextPrefetchState(&executionState, anchorKey: anchorKey)
        self.activeAnchorExecutionState = executionState

        let residentSnapshot = self.timelineSession?.snapshot
        let residentArchivedIds = residentSnapshot?.items.map(\.archivedId) ?? []
        let observerIndex = residentSnapshot?.residentIndex.index(primary: target.primary)
        let effectiveArchivedId = request.anchor.archivedId ?? target.archivedId
        let coverage = effectiveArchivedId.map {
            ChatAnchorContextCoverageResolver.coverage(
                observerIndex: observerIndex,
                residentArchivedIds: residentArchivedIds,
                targetArchivedId: $0,
                archiveState: self.loadChatArchiveStateSnapshot()
            )
        }
        let plan = ChatAnchorContextPrefetchPolicy.plan(
            coverage: coverage ?? ChatAnchorContextCoverage(
                olderLocalCount: observerIndex ?? 0,
                newerLocalCount: max(0, residentArchivedIds.count - (observerIndex ?? 0) - 1),
                olderBoundary: .unknown,
                newerBoundary: .unknown
            ),
            pageSize: self.initialFirstFramePageSize,
            archivedId: effectiveArchivedId,
            targetWindowIncludesAnchor: true
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
        updatedState.contextPrefetchSnapshotGenerationAtStart =
            residentSnapshot?.generation
        updatedState.contextPrefetchRequiredOlderLocalCount =
            (coverage?.olderLocalCount ?? observerIndex ?? 0) +
            (plan.olderPageSize ?? 0)
        updatedState.contextPrefetchRequiredNewerLocalCount =
            (coverage?.newerLocalCount ?? max(
                0,
                residentArchivedIds.count - (observerIndex ?? 0) - 1
            )) + (plan.newerPageSize ?? 0)
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
        var regularRequestPlansByQueryId:
            [String: MessageArchiveManager.RegularChatArchiveRequestPlan] = [:]
        if self.conversationType == .regular {
            if let newerPageSize = plan.newerPageSize,
               let newerQueryId {
                regularRequestPlansByQueryId[newerQueryId] =
                    MessageArchiveManager.regularNewerRequestPlan(
                        jid: self.jid,
                        newestLoadedArchiveId: archivedId,
                        pageSize: newerPageSize
                    )
            }
            if let olderPageSize = plan.olderPageSize,
               let olderQueryId {
                regularRequestPlansByQueryId[olderQueryId] =
                    MessageArchiveManager.regularOlderRequestPlan(
                        jid: self.jid,
                        oldestLoadedArchiveId: archivedId,
                        pageSize: olderPageSize
                    )
            }
        }
        self.performArchiveAction(
            queryIds: queryIds,
            transactionToken: transactionToken,
            regularRequestPlansByQueryId: regularRequestPlansByQueryId,
            requestSource: request.source,
            transportOwnership: .anchorContext,
            { stream, mam in
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
        // Verified archive-engine windows are the only source of presentable
        // context after the hard cut; never materialize detached legacy pages.
        guard !self.archiveEnginePresentationActive else {
            return
        }
        let residentSnapshot = self.timelineSession?.snapshot
        let residentArchivedIds = residentSnapshot?.items.map(\.archivedId) ?? []
        let observerIndex = residentSnapshot?.residentIndex.index(primary: target.primary)
        let effectiveArchivedId = request.anchor.archivedId ?? target.archivedId
        let coverage = effectiveArchivedId.map {
            ChatAnchorContextCoverageResolver.coverage(
                observerIndex: observerIndex,
                residentArchivedIds: residentArchivedIds,
                targetArchivedId: $0,
                archiveState: self.loadChatArchiveStateSnapshot()
            )
        }
        let plan = ChatAnchorContextPrefetchPolicy.plan(
            coverage: coverage ?? ChatAnchorContextCoverage(
                olderLocalCount: observerIndex ?? 0,
                newerLocalCount: max(0, residentArchivedIds.count - (observerIndex ?? 0) - 1),
                olderBoundary: .unknown,
                newerBoundary: .unknown
            ),
            pageSize: self.datasourcePageSize,
            archivedId: effectiveArchivedId,
            targetWindowIncludesAnchor: false
        )

        guard plan.requiresRemoteFetch,
              let archivedId = effectiveArchivedId,
              archivedId.isNotEmpty else {
            return
        }

#if DEBUG || CHAT_PERFORMANCE_LAB
        let performanceFixtureAction = ChatPerformanceFixtureRemoteHistoryAction(
            kind: .anchorContextPrefetch,
            source: request.source,
            newerPageSize: plan.newerPageSize,
            olderPageSize: plan.olderPageSize
        )
        let performanceFixtureDisposition =
            self.performanceFixtureRemoteHistoryActionHandler?(performanceFixtureAction)
        guard ChatPerformanceFixtureRemoteHistoryRoutingPolicy
            .shouldDispatchProductionTransport(
                requiresRemoteFetch: performanceFixtureAction.requiresRemoteFetch,
                fixtureDisposition: performanceFixtureDisposition
            ) else {
            return
        }
#endif

        let newerQueryId = plan.newerPageSize.map { _ in
            "MAM prev history: \(NanoID.new(6))"
        }
        let olderQueryId = plan.olderPageSize.map { _ in
            "MAM next history: \(NanoID.new(6))"
        }
        let queryIds = Set([newerQueryId, olderQueryId].compactMap { $0 })
#if DEBUG || CHAT_PERFORMANCE_LAB
        self.registerPerformanceFixtureDetachedPersistenceQueries(queryIds)
        let persistenceTerminal: ((String) -> Void)? = { [weak self] queryId in
            self?.completePerformanceFixtureDetachedPersistenceQuery(
                queryId
            )
        }
#else
        let persistenceTerminal: ((String) -> Void)? = nil
#endif
        let persistenceTransaction = ChatDetachedRemoteHistoryPersistenceTransaction(
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType,
            queryIds: queryIds,
            terminal: persistenceTerminal
        )

        var regularRequestPlansByQueryId:
            [String: MessageArchiveManager.RegularChatArchiveRequestPlan] = [:]
        if self.conversationType == .regular {
            if let newerPageSize = plan.newerPageSize,
               let newerQueryId {
                regularRequestPlansByQueryId[newerQueryId] =
                    MessageArchiveManager.regularNewerRequestPlan(
                        jid: self.jid,
                        newestLoadedArchiveId: archivedId,
                        pageSize: newerPageSize
                    )
            }
            if let olderPageSize = plan.olderPageSize,
               let olderQueryId {
                regularRequestPlansByQueryId[olderQueryId] =
                    MessageArchiveManager.regularOlderRequestPlan(
                        jid: self.jid,
                        oldestLoadedArchiveId: archivedId,
                        pageSize: olderPageSize
                    )
            }
        }

        self.performArchiveAction(
            queryIds: queryIds,
            detachedPersistenceTransaction: persistenceTransaction,
            regularRequestPlansByQueryId: regularRequestPlansByQueryId,
            requestSource: request.source,
            transportOwnership: .detachedBackground,
            { stream, mam in
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
                        requestCallbacks: persistenceTransaction.requestCallbacks
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
                        requestCallbacks: persistenceTransaction.requestCallbacks
                    )
                }
            }
        )
    }

#if DEBUG || CHAT_PERFORMANCE_LAB
    internal func registerPerformanceFixtureDetachedPersistenceQueries(
        _ queryIds: Set<String>
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        performanceFixtureDetachedPersistenceQueryIds.formUnion(
            queryIds.filter { $0.isNotEmpty }
        )
    }

    internal func completePerformanceFixtureDetachedPersistenceQuery(
        _ queryId: String
    ) {
        let complete = { [weak self] in
            guard let self,
                  self.performanceFixtureDetachedPersistenceQueryIds
                    .remove(queryId) != nil else {
                return
            }
            self.performanceFixtureDetachedPersistenceTerminalHandler?(
                queryId
            )
        }
        if Thread.isMainThread {
            complete()
        } else {
            DispatchQueue.main.async(execute: complete)
        }
    }
#endif

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
        if localMatch == nil,
           ChatPersistenceMaterializedSearchTargetPolicy
            .hasBoundResolutionProof(
                request: request,
                executionState: executionState
            ),
           let snapshot = self.timelineSession?.snapshot {
            let failure = ChatPersistenceMaterializedSearchTargetPolicy
                .boundResolutionFailure(
                    request: request,
                    executionState: executionState,
                    snapshot: snapshot
                ) ?? .targetMissing
            self.failActiveAnchorExecution(
                token: transactionToken,
                failure: failure
            )
            return
        }
        let action = ChatAnchorExecutionPolicy.resumeAction(
            state: executionState,
            hasLocalMatch: localMatch != nil,
            trigger: trigger,
            pageSize: self.initialFirstContentApplyCount == 0
                ? self.initialFirstFramePageSize
                : self.datasourcePageSize
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
                isSynced: self.currentChatIsSyncedForAnchorBootstrap(),
                hasCommittedInitialContent:
                    self.initialFirstContentApplyCount > 0
            )
            self.revealLocalContentForSavedPositionIfNeeded(
                request: request,
                hasLocalMatch: true
            )

            if contextPrefetchMode == .blocking,
               self.prepareContextPrefetchIfNeeded(around: resolved, request: request) {
                return
            }

            if self.initialFirstContentApplyCount == 0,
               self.activeAnchorExecutionState?
                .persistenceMaterializedWindowGeneration != nil {
                _ = self.beginMappedBlockingAnchorPersistencePresentation(
                    request: request,
                    transactionToken: transactionToken
                )
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
                    if contextPrefetchMode == .background,
                       ChatAnchorContextPrefetchDispatchPolicy.phase(for: contextPrefetchMode) == .beforePositioning {
                        self.startBackgroundContextPrefetchIfNeeded(
                            around: positionTarget,
                            request: request
                        )
                    }
                    self.finishActiveAnchorExecution(token: transactionToken)
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
        if self.retainPendingRequestForInitialFrameTerminalIfOwned(request) {
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

        if ChatArchiveWindowPresentationPolicy.shouldDeferOpenMessageRequest(
            isPresentationActive: self.archiveEnginePresentationActive,
            state: self.archiveWindowState,
            committedCoverageGeneration:
                self.archiveWindowCommittedCoverageGeneration,
            pendingSnapshot: self.archiveWindowPendingSnapshot,
            isShowingSkeleton: self.showSkeletonObserver.value
        ) {
            return
        }

        if self.performLoadedOpenMessageRequestIfPossible(request) {
            return
        }

        if self.archiveEnginePresentationActive {
            _ = self.submitArchiveEngineTarget(request)
            return
        }

        guard request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType,
              self.timelineSession != nil else {
            return
        }

#if DEBUG || CHAT_PERFORMANCE_LAB
        if self.pendingOpenMessageGenericExecutionInterceptorForTests?() == true {
            return
        }
#endif

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
              pendingSearchCalendarCompletionRequest == nil,
              activeSearchCalendarCompletionRequest == nil else {
            return
        }

        let scope = ChatSearchResult.Scope(
            owner: owner,
            jid: jid,
            conversationTypeRawValue: conversationType.rawValue
        )
        let displayedCandidates = searchResultPresentations.compactMap { result -> ChatSearchTimestampAnchor? in
            guard result.scope == scope else { return nil }
            return ChatSearchTimestampAnchor(
                id: result.id,
                scope: result.scope,
                anchor: result.anchor
            )
        }
        let nextPresentationGeneration = searchPresentationState.generation &+ 1
        let request = ChatSearchCalendarCompletionRequest(
            id: UUID(),
            generation: UInt64(max(0, nextPresentationGeneration)),
            scope: scope,
            selectedTimestamp: selectedTimestamp,
            displayedCandidates: displayedCandidates,
            displayedCoverage: nil
        )
        pendingSearchCalendarCompletionRequest = request
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
                    self.pendingSearchCalendarCompletionRequest?.id == request.id
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
        let hadPending = pendingSearchCalendarCompletionRequest != nil
        let hadActive = activeSearchCalendarCompletionRequest != nil
        pendingSearchCalendarCompletionRequest = nil
        activeSearchCalendarCompletionRequest = nil
        let cancelled = searchCalendarCompletionCoordinator?.cancel() ?? false
        if case .resolvingDate = searchPresentationState.positioningPhase {
            reduceSearchPresentationState(
                .dateResolutionFinished(generation: searchPresentationState.generation)
            )
        }
        if hadPending || hadActive || cancelled {
            setChatSearchCalendarDateResolutionLoading(false)
        }
        return hadPending || hadActive || cancelled
    }

    private func beginChatSearchCalendarDateResolution(
        _ request: ChatSearchCalendarCompletionRequest
    ) {
        guard pendingSearchCalendarCompletionRequest?.id == request.id,
              searchPresentationState.isActive,
              searchPresentationState.surfaceMode == .calendar,
              currentChatSearchScopeMatches(request.scope) else {
            pendingSearchCalendarCompletionRequest = nil
            setChatSearchCalendarDateResolutionLoading(false)
            return
        }
        pendingSearchCalendarCompletionRequest = nil
        reduceSearchPresentationState(.completeCalendarDate(request.selectedTimestamp))
        guard UInt64(max(0, searchPresentationState.generation)) == request.generation else {
            reduceSearchPresentationState(
                .dateResolutionFinished(generation: searchPresentationState.generation)
            )
            setChatSearchCalendarDateResolutionLoading(false)
            return
        }

        restoreNormalChatChromeForCalendarDateResolution()
        activeSearchCalendarCompletionRequest = request
        let coordinator = configuredSearchCalendarCompletionCoordinator()
        guard coordinator.begin(request, completion: { [weak self] outcome in
            self?.finishChatSearchCalendarDateResolution(request: request, outcome: outcome)
        }) else {
            finishChatSearchCalendarDateResolution(
                request: request,
                outcome: .failed(
                    .init(reason: .requestStartFailed, description: nil)
                )
            )
            return
        }
    }

    private func configuredSearchCalendarCompletionCoordinator()
        -> ChatSearchCalendarCompletionCoordinating {
        if let searchCalendarCompletionCoordinator {
            return searchCalendarCompletionCoordinator
        }
        let transport = ChatSearchTimestampMAMTransport()
        let remoteResolver = ChatSearchTimestampMAMResolver(
            dependencies: .init(
                start: { plan, callbacks in
                    transport.start(plan: plan, callbacks: callbacks)
                },
                cancel: { queryID in
                    transport.cancel(queryID: queryID)
                }
            )
        )
        let coordinator = ChatSearchCalendarCompletionCoordinator(
            localResolver: ChatSearchTimestampResolver(),
            remoteResolver: remoteResolver
        )
        searchCalendarTimestampMAMTransport = transport
        searchCalendarCompletionCoordinator = coordinator
        return coordinator
    }

    private func finishChatSearchCalendarDateResolution(
        request: ChatSearchCalendarCompletionRequest,
        outcome: ChatSearchCalendarCompletionOutcome
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.finishChatSearchCalendarDateResolution(request: request, outcome: outcome)
            }
            return
        }
        guard activeSearchCalendarCompletionRequest?.id == request.id else {
            return
        }
        activeSearchCalendarCompletionRequest = nil
        reduceSearchPresentationState(
            .dateResolutionFinished(generation: Int(request.generation))
        )
        setChatSearchCalendarDateResolutionLoading(false)

        guard currentChatSearchScopeMatches(request.scope) else {
            return
        }
        switch outcome {
        case .resolved(let anchor):
            guard anchor.scope == request.scope,
                  let openRequest = ChatSearchCalendarAnchorRequestFactory.make(
                      anchor: anchor,
                      conversationType: conversationType
                  ) else {
                presentChatSearchCalendarDateResolutionError(
                    generation: Int(request.generation)
                )
                return
            }
            chatScrollDirection = .up
            queueOpenMessageRequest(
                openRequest,
                hooks: ChatAnchorExecutionHooks(
                    direction: .up,
                    animatedScroll: true,
                    onFailed: nil,
                    onPositioned: nil
                )
            )
        case .noMessage:
            announceChatSearchCalendarDateHasNoMessage(
                generation: Int(request.generation)
            )
        case .failed:
            presentChatSearchCalendarDateResolutionError(
                generation: Int(request.generation)
            )
        case .cancelled:
            break
        }
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

    internal func applyTransientMessageHighlight(
        primary: String,
        initialFrameEffectToken: ChatInitialFrameEffectToken? = nil
    ) {
        if let initialFrameEffectToken,
           !self.isLatestInitialFrameEffectToken(initialFrameEffectToken) {
            return
        }
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
            self.postChatSearchAccessibilityAnnouncement(
                .noResults,
                generation: self.searchPresentationState.generation
            )
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
                // Raw MAM <fin> ends transport only. Defer timeout cleanup to
                // the query persistence handler; an off-resident search keeps
                // terminal ownership through materialization and UI release.
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

            if self.initialBootstrapQueryId == queryId {
                let coordinator = ChatInitialBootstrapRequestCoordinator.shared
                if let page = coordinator.cachedCommittedPage(
                    key: self.initialBootstrapRequestKey,
                    queryId: queryId
                ) {
                    self.consumeInitialBootstrapCommittedPage(page)
                } else {
                    ChatArchiveDebugTrace.log("initialBootstrapRawFinalAwaitingCommit", [
                        ("queryId", queryId),
                        ("phase", coordinator.readiness(for: self.initialBootstrapRequestKey)?.phase.rawValue ?? "none")
                    ])
                }
                // The account-scoped coordinator owns both the query flush
                // and deferred MAM coverage commit. Starting a second UI
                // flush here can reveal empty/content before readiness is
                // durable, so raw `<fin>` never completes initial bootstrap.
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

    internal func consumeInitialBootstrapCommittedPage(
        _ page: ChatInitialBootstrapRequestCoordinator.CommittedPage
    ) {
        // Readiness observation already crosses to the main queue. Executing
        // immediately when it arrives prevents a snapshot consumer from
        // completing its lease one run-loop turn before the joined UI records
        // the committed page. Background/cache callers still get one safe hop.
        self.performOnMain { [weak self] in
            guard let self,
                  self.initialBootstrapQueryId == page.event.queryId else {
                return
            }
            let didOwnRawFinal = self.markRemoteHistoryEndPageCompletionIfNeeded(
                queryId: page.event.queryId
            )
            guard didOwnRawFinal ||
                    !self.didReceiveInitialBootstrapEndPage else {
                return
            }
            // A raw-final callback can win before a joined/off-screen
            // controller has installed initialBootstrapQueryId. The durable
            // coordinator page is the presentation authority in that race;
            // an earlier transport dedupe marker must not suppress its first
            // bootstrap consumption.
            self.handleCommittedRemoteHistoryFinal(
                queryId: page.event.queryId,
                originalState: page.event.state,
                first: page.event.first,
                last: page.event.last,
                count: page.event.count,
                completion: page.completion,
                barrierDurationMs: 0
            )
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
    private func beginMappedBlockingAnchorPersistencePresentation(
        request: ChatOpenMessageRequest,
        transactionToken: ChatAnchorTransactionToken
    ) -> Bool {
        guard var state = self.activeAnchorExecutionState,
              state.request == request,
              state.transactionToken == transactionToken,
              !state.isPersistenceMaterializationInFlight,
              self.initialFirstContentApplyCount == 0 else {
            return false
        }
        state.isPersistenceMaterializationInFlight = true
        state.isWaitingForObserverSync = true
        self.activeAnchorExecutionState = state
        self.syncAnchorExecutionFlags()
        return self.prepareMappedAnchorPersistenceWindow(
            request: request,
            transactionToken: transactionToken
        ) { [weak self] result in
            guard let self,
                  var current = self.activeAnchorExecutionState,
                  current.request == request,
                  current.transactionToken == transactionToken,
                  self.anchorTransactionGate.snapshot.activeToken ==
                    transactionToken else {
                return
            }
            current.isPersistenceMaterializationInFlight = false
            current.isWaitingForObserverSync = false
            self.activeAnchorExecutionState = current
            self.syncAnchorExecutionFlags()
            switch result {
            case .committed(let window):
                if request.source == .search {
                    current.persistenceMaterializedWindowGeneration =
                        window.committedSnapshot.generation
                    self.activeAnchorExecutionState = current
                    self.syncAnchorExecutionFlags()
                }
                guard window.committedSnapshot.items.count <=
                        self.initialFirstFramePageSize,
                      let local = self.localAnchorMessage(for: request),
                      let resolved = self.resolvedJumpTarget(
                        for: local.message
                      ),
                      window.committedSnapshot.residentIndex.index(
                        primary: resolved.primary
                      ) != nil,
                      self.hasMaterializedExpectedContext(
                        around: resolved,
                        request: request,
                        state: current
                      ) else {
                    self.initialLocalFirstFrameMappingToken?.cancel()
                    self.initialLocalFirstFrameMappingToken = nil
                    self.initialLocalFirstFramePhase = .blockedMissingTarget(
                        window.descriptor
                    )
                    self.failActiveAnchorExecution(
                        token: transactionToken,
                        failure: .targetMissing
                    )
                    return
                }
                self.presentMappedAnchorPersistenceWindow(window)
            case .failed(let failure):
                self.initialLocalFirstFrameMappingToken?.cancel()
                self.initialLocalFirstFrameMappingToken = nil
                self.initialLocalFirstFramePhase = .blockedMissingTarget(
                    ChatLocalFirstFrameDescriptorPolicy.descriptor(
                        request: request,
                        owner: self.owner,
                        jid: self.jid,
                        conversationType: self.conversationType
                    )
                )
                self.failActiveAnchorExecution(
                    token: transactionToken,
                    failure: failure
                )
            case .blocked, .rejected, .stale:
                self.initialLocalFirstFrameMappingToken?.cancel()
                self.initialLocalFirstFrameMappingToken = nil
                self.initialLocalFirstFramePhase = .blockedMissingTarget(
                    ChatLocalFirstFrameDescriptorPolicy.descriptor(
                        request: request,
                        owner: self.owner,
                        jid: self.jid,
                        conversationType: self.conversationType
                    )
                )
                self.failActiveAnchorExecution(
                    token: transactionToken,
                    failure: .targetMissing
                )
            }
        }
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
        // RSM <count> is the server collection cardinality, not this page's
        // delivered row count. The post-persistence summary is the only
        // truthful materialization budget for the initial target window.
        executionState.contextPrefetchExpectedMessageCount +=
            max(0, state.persistedMessageCount)
        executionState.contextPrefetchPersistedMessageCount += state.persistedMessageCount
        self.activeAnchorExecutionState = executionState
        self.syncAnchorExecutionFlags()

        if executionState.contextPrefetchPendingQueryIds.isEmpty,
           self.initialFirstContentApplyCount == 0,
           let request = self.pendingOpenMessageRequest {
            return self.beginMappedBlockingAnchorPersistencePresentation(
                request: request,
                transactionToken: executionState.transactionToken
            )
        }

        let request = self.pendingOpenMessageRequest
        let resolvedTarget = request.flatMap { request in
            self.localAnchorMessage(for: request).flatMap {
                self.resolvedJumpTarget(for: $0.message)
            } ?? request.anchor.messagePrimary.map {
                ResolvedJumpTarget(
                    primary: $0,
                    archivedId: request.anchor.archivedId
                )
            }
        }
        let hasMaterializedExpectedContext: Bool
        if let request,
           let resolvedTarget {
            hasMaterializedExpectedContext =
                self.hasMaterializedExpectedContext(
                    around: resolvedTarget,
                    request: request,
                    state: executionState
                )
        } else {
            hasMaterializedExpectedContext = false
        }

        let action = ChatAnchorContextPrefetchPolicy.completionAction(
            pendingQueryIds: executionState.contextPrefetchPendingQueryIds,
            totalPersistedMessageCount:
                executionState.contextPrefetchPersistedMessageCount,
            hasMaterializedExpectedContext:
                hasMaterializedExpectedContext
        )

        switch action {
        case .waitForMoreQueries:
            return true
        case .waitForObserverSync:
            executionState.didObserveContextPostIdleTick = false
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            // This is a zero-delay causality probe only. Persisted rows still
            // require a strictly newer TimelineSession generation, so this
            // callback cannot admit a target-only frame; the real observer
            // update is what resumes the transaction.
            self.scheduleContextPrefetchObserverResumeIfNeeded()
            return true
        case .complete:
            self.activeAnchorExecutionState = executionState
            self.syncAnchorExecutionFlags()
            self.resumeAnchorExecutionIfNeeded(trigger: .manual)
            return true
        }
    }

#if DEBUG || CHAT_PERFORMANCE_LAB
    /// Focused integration seam: exercises the production persistence-terminal
    /// reducer without fabricating an XMPP transport. Snapshot readiness still
    /// comes exclusively from the installed real `ChatTimelineSession`.
    @discardableResult
    internal func performanceTestConsumeAnchorContextPersistenceTerminal(
        queryId: String,
        persistedMessageCount: Int
    ) -> Bool {
        handleAnchorContextPrefetchEndPageIfNeeded(
            queryId: queryId,
            state: MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: persistedMessageCount
            ),
            count: persistedMessageCount
        )
    }

    /// Focused integration seam for the real remote-exact persistence
    /// terminal. `serverResultCardinality` deliberately models an unrelated
    /// RSM collection count; production readiness must depend only on the
    /// persistence proof and a newer `ChatTimelineSession` generation.
    @discardableResult
    internal func performanceTestConsumeAnchorRemotePersistenceTerminal(
        queryId: String,
        serverResultCardinality: Int,
        persistedMessageCount: Int
    ) -> Bool {
        if let transactionToken = self.anchorTransactionTokenByQueryId[queryId] {
            guard self.anchorTransactionGate.accept(
                .persistence(queryId: queryId),
                token: transactionToken
            ) == .accepted else {
                return false
            }
        }
        return handleAnchorRemoteFetchEndPageIfNeeded(
            queryId: queryId,
            state: MessageArchivePageEndState(
                queryExhausted: false,
                archiveEnded: false,
                persistedMessageCount: persistedMessageCount
            ),
            count: serverResultCardinality
        )
    }
#endif

    private func shouldMaterializeAnchorPersistenceWindow(
        request: ChatOpenMessageRequest,
        persistedMessageCount: Int
    ) -> Bool {
        guard persistedMessageCount > 0,
              self.localAnchorMessage(for: request) == nil else {
            return false
        }
        if request.source == .search {
            // A search result can already exist in Realm while remaining
            // outside the bounded resident observation. An updated-existing
            // persistence summary therefore cannot rely on an observer tick;
            // bind and commit the bounded provider window explicitly.
            return true
        }
        guard self.initialFirstContentApplyCount == 0 else {
            return false
        }
        let descriptor = ChatLocalFirstFrameDescriptorPolicy.descriptor(
            request: request,
            owner: self.owner,
            jid: self.jid,
            conversationType: self.conversationType
        )
        guard case .blockedMissingTarget(let blockedDescriptor) =
                self.initialLocalFirstFramePhase else {
            return false
        }
        return blockedDescriptor == descriptor
    }

    private func beginAnchorPersistenceWindowMaterialization(
        request: ChatOpenMessageRequest,
        transactionToken: ChatAnchorTransactionToken,
        persistedMessageCount: Int
    ) {
        guard var executionState = self.activeAnchorExecutionState,
              executionState.transactionToken == transactionToken,
              !executionState.isPersistenceMaterializationInFlight else {
            return
        }
        executionState.isWaitingForObserverSync = true
        executionState.isPersistenceMaterializationInFlight = true
        self.activeAnchorExecutionState = executionState
        self.syncAnchorExecutionFlags()
        _ = self.prepareAnchorPersistenceWindow(
            request: request,
            transactionToken: transactionToken
        ) { [weak self] result in
            guard let self,
                  var current = self.activeAnchorExecutionState,
                  current.request == request,
                  current.transactionToken == transactionToken,
                  self.anchorTransactionGate.snapshot.activeToken ==
                    transactionToken else {
                return
            }
            current.isWaitingForObserverSync = false
            current.isPersistenceMaterializationInFlight = false
            let completedExplicitProbe: Bool
            switch result {
            case .committed(let snapshot, let searchResolutionProof):
                current.persistenceMaterializedWindowGeneration =
                    snapshot.generation
                current.persistenceSearchResolutionProof =
                    searchResolutionProof
                completedExplicitProbe = true
            case .failed(let failure):
                self.activeAnchorExecutionState = current
                self.syncAnchorExecutionFlags()
                self.failActiveAnchorExecution(
                    token: transactionToken,
                    failure: failure
                )
                return
            case .blocked, .rejected:
                self.activeAnchorExecutionState = current
                self.syncAnchorExecutionFlags()
                self.failActiveAnchorExecution(
                    token: transactionToken,
                    failure: .targetMissing
                )
                return
            case .stale:
                self.activeAnchorExecutionState = current
                self.syncAnchorExecutionFlags()
                self.failActiveAnchorExecution(
                    token: transactionToken,
                    failure: .targetMissing
                )
                return
            }
            self.activeAnchorExecutionState = current
            self.syncAnchorExecutionFlags()
            self.evaluateAnchorRemotePersistenceCompletion(
                persistedMessageCount: persistedMessageCount,
                completedExplicitMaterializationProbe:
                    completedExplicitProbe
            )
        }
    }

    private func evaluateAnchorRemotePersistenceCompletion(
        persistedMessageCount: Int,
        completedExplicitMaterializationProbe: Bool
    ) {
        guard var executionState = self.activeAnchorExecutionState else {
            return
        }
        let hasLocalMatch = self.pendingOpenMessageRequest
            .flatMap { self.localAnchorMessage(for: $0) } != nil
        if !hasLocalMatch,
           let request = self.pendingOpenMessageRequest,
           ChatPersistenceMaterializedSearchTargetPolicy
            .hasBoundResolutionProof(
                request: request,
                executionState: executionState
            ),
           let snapshot = self.timelineSession?.snapshot {
            let failure = ChatPersistenceMaterializedSearchTargetPolicy
                .boundResolutionFailure(
                    request: request,
                    executionState: executionState,
                    snapshot: snapshot
                ) ?? .targetMissing
            self.failActiveAnchorExecution(
                token: executionState.transactionToken,
                failure: failure
            )
            return
        }
        let observedGeneration = self.timelineSession?.snapshot.generation ?? 0
        let shouldWaitForNewerSnapshot =
            ChatAnchorRemoteObserverBarrierPolicy.shouldWaitForNewerSnapshot(
                persistedMessageCount: persistedMessageCount,
                baselineGeneration:
                    executionState.remoteFetchSnapshotGenerationAtStart,
                observedGeneration: observedGeneration
            )
        let action = ChatAnchorExecutionPolicy.remoteCompletionAction(
            state: executionState,
            hasLocalMatch: hasLocalMatch,
            persistedMessageCount: persistedMessageCount,
            hasObservedNewerSnapshot:
                completedExplicitMaterializationProbe ||
                !shouldWaitForNewerSnapshot,
            pageSize: self.initialFirstContentApplyCount == 0
                ? self.initialFirstFramePageSize
                : self.datasourcePageSize
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
                .map { self.typedAnchorResolutionFailure(for: $0) } ??
                .targetMissing
            self.failActiveAnchorExecution(failure: failure)
        case .none:
            self.syncAnchorExecutionFlags()
        }
    }

    @discardableResult
    private func handleAnchorRemoteFetchEndPageIfNeeded(
        queryId: String,
        state: MessageArchivePageEndState,
        count _: Int
    ) -> Bool {
        guard var executionState = self.activeAnchorExecutionState,
              executionState.remoteQueryId == queryId else {
            return false
        }

        let request = self.pendingOpenMessageRequest
        let shouldMaterializePersistenceWindow = request.map {
            self.shouldMaterializeAnchorPersistenceWindow(
                request: $0,
                persistedMessageCount: state.persistedMessageCount
            )
        } ?? false
        if shouldMaterializePersistenceWindow {
            self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)
        } else {
            self.anchorTransactionTokenByQueryId.removeValue(forKey: queryId)
            self.anchorTransactionTimeoutWorkItems
                .removeValue(forKey: queryId)?
                .cancel()
            self.unregisterRemoteHistoryPersistenceSource(queryId: queryId)
        }

        executionState.isRemoteFetchInFlight = false
        if !shouldMaterializePersistenceWindow {
            executionState.remoteQueryId = nil
        }
        executionState.isPositioning = false
        self.activeAnchorExecutionState = executionState
        self.syncAnchorExecutionFlags()

        if let request,
           shouldMaterializePersistenceWindow {
            self.beginAnchorPersistenceWindowMaterialization(
                request: request,
                transactionToken: executionState.transactionToken,
                persistedMessageCount: state.persistedMessageCount
            )
            return true
        }

        self.evaluateAnchorRemotePersistenceCompletion(
            persistedMessageCount: state.persistedMessageCount,
            completedExplicitMaterializationProbe: false
        )

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
        case .serverError, .malformedResponse:
            failure = .iqError
        }
        self.failActiveAnchorExecution(token: transactionToken, failure: failure)
        return true
    }
}
