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
import RxSwift
import RxCocoa
import RxRealm
import DeepDiff
import CocoaLumberjack
import MaterialComponents.MDCPalettes
import XMPPFramework

struct ChatDatasourceSnapshot {
    static let empty = ChatDatasourceSnapshot(
        items: [],
        primaryIndex: [:],
        archivedIdIndex: [:],
        hasDuplicatePrimaries: false,
        hasDuplicateArchivedIds: false
    )

    let items: [ChatViewController.Datasource]
    let primaryIndex: [String: Int]
    let archivedIdIndex: [String: Int]
    let hasDuplicatePrimaries: Bool
    let hasDuplicateArchivedIds: Bool

    var hasDuplicateKeys: Bool {
        hasDuplicatePrimaries || hasDuplicateArchivedIds
    }

    init(items: [ChatViewController.Datasource]) {
        self.items = items
        var primaryIndex: [String: Int] = [:]
        var archivedIdIndex: [String: Int] = [:]
        var duplicatePrimaryCount = 0
        var duplicateArchivedIdCount = 0

        for (offset, item) in items.enumerated() {
            if primaryIndex.updateValue(offset, forKey: item.primary) != nil {
                duplicatePrimaryCount += 1
            }

            guard let archivedId = item.archivedId, archivedId.isNotEmpty else { continue }

            if archivedIdIndex.updateValue(offset, forKey: archivedId) != nil {
                duplicateArchivedIdCount += 1
            }
        }

        self.primaryIndex = primaryIndex
        self.archivedIdIndex = archivedIdIndex
        self.hasDuplicatePrimaries = duplicatePrimaryCount > 0
        self.hasDuplicateArchivedIds = duplicateArchivedIdCount > 0

        if duplicatePrimaryCount > 0 || duplicateArchivedIdCount > 0 {
            DDLogWarn(
                "ChatDatasourceSnapshot detected duplicate keys. primary duplicates: \(duplicatePrimaryCount); archivedId duplicates: \(duplicateArchivedIdCount)"
            )
        }
    }

    init(
        items: [ChatViewController.Datasource],
        primaryIndex: [String: Int],
        archivedIdIndex: [String: Int],
        hasDuplicatePrimaries: Bool,
        hasDuplicateArchivedIds: Bool
    ) {
        self.items = items
        self.primaryIndex = primaryIndex
        self.archivedIdIndex = archivedIdIndex
        self.hasDuplicatePrimaries = hasDuplicatePrimaries
        self.hasDuplicateArchivedIds = hasDuplicateArchivedIds
    }
}

struct ChatDatasetWindow: Equatable {
    static let empty = ChatDatasetWindow(minIndex: 0, maxIndex: 0)

    let minIndex: Int
    let maxIndex: Int

    var isEmpty: Bool {
        maxIndex <= minIndex
    }

    var count: Int {
        max(0, maxIndex - minIndex)
    }
}

enum ChatHistoryPageDirection: Equatable {
    case older
    case newer
}

enum ChatHistoryPagingLoadDecision: Equatable {
    case localOnly
    case remoteOlderPage
    case remoteNewerPage
    case endReached
}

struct ChatInteractiveHistoryPageLoadContext {
    let queryId: String
    let direction: ChatHistoryPageDirection
    let chatPrimaryKey: String
    let persistedCursorId: String?
    let persistedFullArchiveLoaded: Bool
    let requestedCursorId: String?
    let requestedWindow: ChatDatasetWindow
    let preLoadObserverCount: Int
    let preLoadOldestArchivedId: String?
    let preLoadFullArchiveLoaded: Bool
    let remoteFetchStarted: Bool
    let isArchiveEndVerificationProbe: Bool
    let expectedWindowMaxIndex: Int
    var didReceiveEndPage: Bool = false
    var queryExhausted: Bool = false
    var persistedMessageCount: Int? = nil
    var resultFirst: String = ""
    var resultLast: String = ""
    var didEnterObserverSettlePhase: Bool = false
    var didObservePostIdleTick: Bool = false
}

struct ChatHistoryPageAnchor: Equatable {
    let primary: String
    let offsetFromViewportTop: CGFloat
}

struct ChatHistoryPagingBoundaryContext: Equatable {
    let firstRealSection: Int?
    let lastRealSection: Int?
    let visibleRealSections: [Int]
}

enum ChatHistoryPageCompletionPolicy {
    static func shouldFinish(
        didReceiveEndPage: Bool,
        didAdvance: Bool,
        persistedMessageCount: Int?,
        isMessagePipelineIdle: Bool,
        requiresObserverSettle: Bool = false,
        didObservePostIdleTick: Bool = true
    ) -> Bool {
        guard didReceiveEndPage, isMessagePipelineIdle else {
            return false
        }

        if requiresObserverSettle && !didObservePostIdleTick {
            return false
        }

        if didAdvance {
            return true
        }

        return persistedMessageCount == 0
    }

    static func didAdvance(
        previousObserverCount: Int,
        currentObserverCount: Int,
        previousOldestArchivedId: String?,
        currentOldestArchivedId: String?,
        previousArchiveEnded: Bool,
        currentArchiveEnded: Bool
    ) -> Bool {
        currentObserverCount > previousObserverCount ||
        previousOldestArchivedId != currentOldestArchivedId ||
        (!previousArchiveEnded && currentArchiveEnded)
    }
}

enum ChatInitialBootstrapCompletionPolicy {
    static func shouldFinish(
        didReceiveEndPage: Bool,
        hasMessages: Bool,
        didConfirmEmpty: Bool,
        isMessagePipelineIdle: Bool,
        requiresObserverSettle: Bool,
        didObservePostIdleTick: Bool
    ) -> Bool {
        guard didReceiveEndPage,
              isMessagePipelineIdle,
              hasMessages || didConfirmEmpty else {
            return false
        }

        guard !requiresObserverSettle || didObservePostIdleTick else {
            return false
        }

        return true
    }
}

enum ChatHistoryPageApplyPolicy {
    static func keepOffset(direction: ChatHistoryPageDirection) -> Bool {
        switch direction {
        case .older:
            return true
        case .newer:
            return false
        }
    }
}

enum ChatHistoryPageAnchorRestorePolicy {
    static func targetContentOffsetY(
        anchorMinY: CGFloat,
        offsetFromViewportTop: CGFloat,
        minContentOffsetY: CGFloat,
        maxContentOffsetY: CGFloat
    ) -> CGFloat {
        min(max(anchorMinY - offsetFromViewportTop, minContentOffsetY), maxContentOffsetY)
    }
}

enum ChatHistoryLoadingTimeoutPolicy {
    static let checkInterval: TimeInterval = 5.0
    static let interactiveHardTimeout: TimeInterval = 180.0

    static func shouldAbortInteractivePageLoad(elapsed: TimeInterval) -> Bool {
        elapsed >= interactiveHardTimeout
    }
}

enum ChatDatasourceApplyGenerationPolicy {
    static func shouldApply(requestGeneration: Int, currentGeneration: Int) -> Bool {
        requestGeneration == currentGeneration
    }
}

enum ChatHistoryPageOutcome: Equatable {
    case advanced(persistedCursorId: String?)
    case emptyExhausted(persistedCursorId: String?)
    case duplicateOrNoAdvance(persistedCursorId: String?)
}

enum ChatHistoryPageOutcomePolicy {
    static func resolve(
        queryExhausted: Bool,
        didAdvance: Bool,
        persistedMessageCount: Int,
        requestedCursorId: String?,
        currentCursorId: String?
    ) -> ChatHistoryPageOutcome {
        if didAdvance {
            return .advanced(persistedCursorId: currentCursorId)
        }

        if queryExhausted && persistedMessageCount == 0 && requestedCursorId == currentCursorId {
            return .emptyExhausted(persistedCursorId: currentCursorId)
        }

        return .duplicateOrNoAdvance(persistedCursorId: currentCursorId)
    }
}

struct ChatArchiveStateSnapshot: Equatable {
    let primaryKey: String
    let persistedCursorId: String?
    let fullArchiveLoaded: Bool
    let newestCursorId: String?
    let newerLiveEdgeReached: Bool
    let hasKnownNewerGap: Bool

    init(
        primaryKey: String,
        persistedCursorId: String?,
        fullArchiveLoaded: Bool,
        newestCursorId: String? = nil,
        newerLiveEdgeReached: Bool = true,
        hasKnownNewerGap: Bool = false
    ) {
        self.primaryKey = primaryKey
        self.persistedCursorId = persistedCursorId
        self.fullArchiveLoaded = fullArchiveLoaded
        self.newestCursorId = newestCursorId
        self.newerLiveEdgeReached = newerLiveEdgeReached
        self.hasKnownNewerGap = hasKnownNewerGap
    }
}

struct ChatArchiveStateMutationPlan: Equatable {
    let resolvedCursorId: String?
    let fullArchiveLoaded: Bool
    let shouldWriteCursor: Bool
    let shouldWriteFullArchiveLoaded: Bool

    var needsWrite: Bool {
        shouldWriteCursor || shouldWriteFullArchiveLoaded
    }
}

struct ChatObserverLookupMaps: Equatable {
    let primaryIndex: [String: Int]
    let archivedIdIndex: [String: Int]
    let messageIdIndex: [String: Int]
    let oldestArchivedId: String?
    let newestArchivedId: String?
}

enum ChatObserverLookupPolicy {
    static func build<T: Sequence>(from items: T) -> ChatObserverLookupMaps where T.Element == MessageStorageItem {
        var primaryIndex: [String: Int] = [:]
        var archivedIdIndex: [String: Int] = [:]
        var messageIdIndex: [String: Int] = [:]
        var oldestArchivedId: String?
        var newestArchivedId: String?

        for (offset, item) in items.enumerated() {
            primaryIndex[item.primary] = offset
            if item.archivedId.isNotEmpty {
                let archivedId = item.archivedId
                archivedIdIndex[archivedId] = offset
                if oldestArchivedId == nil {
                    oldestArchivedId = archivedId
                }
                newestArchivedId = archivedId
            }
            if item.messageId.isNotEmpty {
                messageIdIndex[item.messageId] = offset
            }
        }

        return ChatObserverLookupMaps(
            primaryIndex: primaryIndex,
            archivedIdIndex: archivedIdIndex,
            messageIdIndex: messageIdIndex,
            oldestArchivedId: oldestArchivedId,
            newestArchivedId: newestArchivedId
        )
    }
}

enum ChatUnreadMentionNavigatorMode: Equatable {
    case hidden
    case indicator
}

struct ChatUnreadMentionItem: Equatable {
    let notificationPrimary: String?
    let messagePrimary: String?
    let archivedId: String?
    let messageId: String?
    let chatPrimary: String
    let authorId: String?
    let date: Date
    let targetMemberId: String?
    let groupchatJid: String
}

struct ChatUnreadMentionNavigationTarget: Equatable {
    let notificationPrimary: String?
    let messagePrimary: String?
    let archivedId: String?
    let messageId: String?
    let authorId: String?
    let date: Date
    let observerIndex: Int?
}

struct ChatUnreadMentionNavigationRequest: Equatable {
    let target: ChatUnreadMentionNavigationTarget
    let direction: ChatViewController.ChatDirection
}

struct ChatUnreadMentionsState: Equatable {
    static let empty = ChatUnreadMentionsState(
        items: [],
        unreadCount: 0,
        visibleUnreadNotificationPrimaries: Set(),
        currentTarget: nil,
        jumpTarget: nil,
        mode: .hidden
    )

    let items: [ChatUnreadMentionItem]
    let unreadCount: Int
    let visibleUnreadNotificationPrimaries: Set<String>
    let currentTarget: ChatUnreadMentionNavigationTarget?
    let jumpTarget: ChatUnreadMentionNavigationTarget?
    let mode: ChatUnreadMentionNavigatorMode

    var hasUnreadMentions: Bool {
        unreadCount > 0
    }
}

enum ChatUnreadMentionMatcher {
    private static func resolveMessagePrimary(
        for notification: NotificationStorageItem,
        messagesObserver: Results<MessageStorageItem>,
        observerLookupMaps: ChatObserverLookupMaps,
        in realm: Realm
    ) -> String? {
        if let archivedId = notification.sourceArchivedId,
           archivedId.isNotEmpty,
           let observerIndex = observerLookupMaps.archivedIdIndex[archivedId],
           observerIndex < messagesObserver.count {
            return messagesObserver[observerIndex].primary
        }

        if let messageId = notification.sourceMessageId,
           messageId.isNotEmpty,
           let observerIndex = observerLookupMaps.messageIdIndex[messageId],
           observerIndex < messagesObserver.count {
            return messagesObserver[observerIndex].primary
        }

        return MentionNotificationSync.matchingMessage(for: notification, in: realm)?.primary
    }

    static func unreadMentionItem(
        from notification: NotificationStorageItem,
        messagesObserver: Results<MessageStorageItem>,
        observerLookupMaps: ChatObserverLookupMaps,
        in realm: Realm,
        chatPrimary: String,
        currentMemberId: String?,
        groupchatJid: String
    ) -> ChatUnreadMentionItem? {
        guard notification.isMentionNotification,
              !notification.isRead,
              notification.sourceChatJid == groupchatJid,
              notification.sourceConversationType == nil || notification.sourceConversationType == .group,
              notification.mentionLinkStatus != .invalidated,
              notification.mentionLinkStatus != .missing else {
            return nil
        }

        let archivedId = notification.sourceArchivedId?.isNotEmpty == true ? notification.sourceArchivedId : nil
        let messageId = notification.sourceMessageId?.isNotEmpty == true ? notification.sourceMessageId : nil

        guard archivedId != nil || messageId != nil else {
            return nil
        }

        let targetMemberId = notification.mentionTargetUserId ?? currentMemberId

        if let authorId = notification.sourceSenderId,
           authorId.isNotEmpty,
           let targetMemberId,
           targetMemberId.isNotEmpty,
           authorId == targetMemberId {
            return nil
        }

        return ChatUnreadMentionItem(
            notificationPrimary: notification.primary,
            messagePrimary: resolveMessagePrimary(
                for: notification,
                messagesObserver: messagesObserver,
                observerLookupMaps: observerLookupMaps,
                in: realm
            ),
            archivedId: archivedId,
            messageId: messageId,
            chatPrimary: chatPrimary,
            authorId: notification.sourceSenderId,
            date: notification.sourceMessageDate ?? notification.date,
            targetMemberId: targetMemberId,
            groupchatJid: groupchatJid
        )
    }
}

enum ChatUnreadMentionIndexPolicy {
    static func rebuild(
        from notifications: Results<NotificationStorageItem>,
        messagesObserver: Results<MessageStorageItem>,
        observerLookupMaps: ChatObserverLookupMaps,
        in realm: Realm,
        chatPrimary: String,
        currentMemberId: String?,
        groupchatJid: String
    ) -> [ChatUnreadMentionItem] {
        var seenKeys: Set<String> = []
        return notifications.compactMap {
            ChatUnreadMentionMatcher.unreadMentionItem(
                from: $0,
                messagesObserver: messagesObserver,
                observerLookupMaps: observerLookupMaps,
                in: realm,
                chatPrimary: chatPrimary,
                currentMemberId: currentMemberId,
                groupchatJid: groupchatJid
            )
        }.filter {
            let key = $0.archivedId ?? $0.messageId ?? $0.notificationPrimary ?? $0.chatPrimary
            return seenKeys.insert(key).inserted
        }
    }
}

enum ChatUnreadMentionFallbackPolicy {
    static func fallbackItem(
        mentionId: String?,
        chatPrimary: String,
        currentMemberId: String?,
        groupchatJid: String,
        date: Date
    ) -> ChatUnreadMentionItem? {
        guard let mentionId,
              mentionId.isNotEmpty else {
            return nil
        }

        return ChatUnreadMentionItem(
            notificationPrimary: nil,
            messagePrimary: nil,
            archivedId: mentionId,
            messageId: nil,
            chatPrimary: chatPrimary,
            authorId: nil,
            date: date,
            targetMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )
    }
}

enum ChatUnreadMentionNavigationPolicy {
    private static func order(_ lhs: ChatUnreadMentionNavigationTarget, _ rhs: ChatUnreadMentionNavigationTarget) -> Bool {
        if let leftIndex = lhs.observerIndex,
           let rightIndex = rhs.observerIndex,
           leftIndex != rightIndex {
            return leftIndex > rightIndex
        }

        if lhs.date != rhs.date {
            return lhs.date > rhs.date
        }

        let leftKey = lhs.archivedId ?? lhs.messageId ?? lhs.notificationPrimary ?? ""
        let rightKey = rhs.archivedId ?? rhs.messageId ?? rhs.notificationPrimary ?? ""
        return leftKey < rightKey
    }

    static func resolveState(
        items: [ChatUnreadMentionItem],
        observerPrimaryIndexMap: [String: Int],
        visiblePrimaries: Set<String>,
        preferredArchivedId: String? = nil,
        selectedNotificationPrimary: String? = nil
    ) -> ChatUnreadMentionsState {
        let targets = items
            .compactMap { item -> ChatUnreadMentionNavigationTarget? in
                return ChatUnreadMentionNavigationTarget(
                    notificationPrimary: item.notificationPrimary,
                    messagePrimary: item.messagePrimary,
                    archivedId: item.archivedId,
                    messageId: item.messageId,
                    authorId: item.authorId,
                    date: item.date,
                    observerIndex: item.messagePrimary.flatMap { observerPrimaryIndexMap[$0] }
                )
            }
            .sorted(by: order)

        guard !targets.isEmpty else {
            return .empty
        }

        let visibleUnreadNotificationPrimaries = Set<String>(targets.compactMap { target in
            guard let messagePrimary = target.messagePrimary,
                  visiblePrimaries.contains(messagePrimary) else {
                return nil
            }
            return target.notificationPrimary
        })

        let preferredHintTarget = preferredArchivedId.flatMap { archivedId in
            targets.first(where: { $0.archivedId == archivedId })
        }

        let selectedTarget = selectedNotificationPrimary.flatMap { notificationPrimary in
            targets.first(where: { $0.notificationPrimary == notificationPrimary })
        }

        let visibleTarget = targets.first(where: { target in
            guard let messagePrimary = target.messagePrimary else {
                return false
            }
            return visiblePrimaries.contains(messagePrimary)
        })

        let currentTarget = selectedTarget ?? visibleTarget ?? preferredHintTarget ?? targets.first
        let jumpTarget: ChatUnreadMentionNavigationTarget?

        if let visibleTarget,
           let visibleIndex = targets.firstIndex(where: { $0.notificationPrimary == visibleTarget.notificationPrimary }),
           (visibleIndex + 1) < targets.count {
            jumpTarget = targets[visibleIndex + 1]
        } else {
            jumpTarget = currentTarget
        }

        let mode: ChatUnreadMentionNavigatorMode = .indicator

        return ChatUnreadMentionsState(
            items: items,
            unreadCount: targets.count,
            visibleUnreadNotificationPrimaries: visibleUnreadNotificationPrimaries,
            currentTarget: currentTarget,
            jumpTarget: jumpTarget,
            mode: mode
        )
    }
}

enum ChatUnreadMentionFloatingControlPolicy {
    static func shouldShowNavigator(
        conversationType: ClientSynchronizationManager.ConversationType,
        unreadCount: Int,
        isSearchMode: Bool
    ) -> Bool {
        conversationType == .group && unreadCount > 0 && !isSearchMode
    }

    static func shouldShowScrollDownButton(
        requested: Bool,
        navigatorVisible _: Bool
    ) -> Bool {
        requested
    }
}

enum ChatArchiveStateMutationPolicy {
    static func resolveCursorId(
        observedCursorId: String?,
        transportFirst: String,
        transportLast: String,
        currentPersistedCursorId: String?
    ) -> String? {
        let currentCursorId = currentPersistedCursorId?.isNotEmpty == true ? currentPersistedCursorId : nil
        let fallbackCursorId = MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
            purpose: .pageOlder,
            first: transportFirst,
            last: transportLast,
            current: currentCursorId
        )
        let resolvedCursorId = observedCursorId ?? currentCursorId ?? fallbackCursorId
        guard let resolvedCursorId, resolvedCursorId.isNotEmpty else {
            return nil
        }
        return resolvedCursorId
    }

    static func resolvePlan(
        snapshot: ChatArchiveStateSnapshot,
        resolvedCursorId: String?,
        nextFullArchiveLoaded: Bool
    ) -> ChatArchiveStateMutationPlan {
        let currentCursorId = snapshot.persistedCursorId?.isNotEmpty == true ? snapshot.persistedCursorId : nil
        return ChatArchiveStateMutationPlan(
            resolvedCursorId: resolvedCursorId,
            fullArchiveLoaded: nextFullArchiveLoaded,
            shouldWriteCursor: resolvedCursorId != nil && resolvedCursorId != currentCursorId,
            shouldWriteFullArchiveLoaded: snapshot.fullArchiveLoaded != nextFullArchiveLoaded
        )
    }
}

enum ChatArchiveEndVerificationPolicy {
    static func shouldProbePersistedArchiveEnd(
        persistedArchiveEnded: Bool,
        hasConfirmedArchiveEndThisSession: Bool,
        hasUsedVerificationProbe: Bool
    ) -> Bool {
        persistedArchiveEnded &&
        !hasConfirmedArchiveEndThisSession &&
        !hasUsedVerificationProbe
    }

    static func effectiveArchiveEnded(
        persistedArchiveEnded: Bool,
        shouldProbePersistedArchiveEnd: Bool
    ) -> Bool {
        persistedArchiveEnded && !shouldProbePersistedArchiveEnd
    }
}

enum ChatHistoryCursorSelectionPolicy {
    static func oldestCursorId(
        observedArchivedIds: [String],
        persistedCursorId: String?
    ) -> String? {
        if let observedCursorId = observedArchivedIds.first(where: { $0.isNotEmpty }) {
            return observedCursorId
        }

        guard let persistedCursorId, persistedCursorId.isNotEmpty else {
            return nil
        }
        return persistedCursorId
    }
}

enum ChatHistoryPagingPolicy {
    private static func boundaryAvailability(
        boundaryContext: ChatHistoryPagingBoundaryContext,
        currentPageMinIndex: Int,
        currentPageMaxIndex: Int,
        totalCount: Int,
        hasRemoteNewerAvailable: Bool = false
    ) -> (olderVisible: Bool, newerVisible: Bool) {
        let minVisibleSection = boundaryContext.visibleRealSections.min()
        let maxVisibleSection = boundaryContext.visibleRealSections.max()

        let olderVisible = currentPageMinIndex > 0 && (minVisibleSection.flatMap { visibleSection in
            boundaryContext.firstRealSection.map { visibleSection <= $0 }
        } ?? false)
        let newerVisible = (currentPageMaxIndex < totalCount || hasRemoteNewerAvailable) && (maxVisibleSection.flatMap { visibleSection in
            boundaryContext.lastRealSection.map { visibleSection >= $0 }
        } ?? false)

        return (olderVisible, newerVisible)
    }

    private static func directionForBoundaryDrag(
        gestureTranslationY: CGFloat,
        boundary: (olderVisible: Bool, newerVisible: Bool)
    ) -> ChatHistoryPageDirection? {
        switch boundary {
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

    static func triggerDirection(
        isUserScrolling: Bool,
        canLoadDatasource: Bool,
        gestureTranslationY: CGFloat,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        currentPageMinIndex: Int,
        currentPageMaxIndex: Int,
        totalCount: Int,
        hasRemoteNewerAvailable: Bool = false
    ) -> ChatHistoryPageDirection? {
        guard isUserScrolling,
              canLoadDatasource,
              !boundaryContext.visibleRealSections.isEmpty else {
            return nil
        }

        let boundary = boundaryAvailability(
            boundaryContext: boundaryContext,
            currentPageMinIndex: currentPageMinIndex,
            currentPageMaxIndex: currentPageMaxIndex,
            totalCount: totalCount,
            hasRemoteNewerAvailable: hasRemoteNewerAvailable
        )

        return directionForBoundaryDrag(
            gestureTranslationY: gestureTranslationY,
            boundary: boundary
        )
    }

    static func loadDecision(
        direction: ChatHistoryPageDirection,
        currentWindow: ChatDatasetWindow,
        requestedWindow: ChatDatasetWindow,
        localWindow: ChatDatasetWindow,
        totalCount: Int,
        isArchiveEnded: Bool,
        hasKnownNewerGap: Bool = false,
        newerLiveEdgeReached: Bool = true
    ) -> ChatHistoryPagingLoadDecision {
        switch direction {
        case .newer:
            guard requestedWindow.maxIndex > totalCount || localWindow.maxIndex < requestedWindow.maxIndex else {
                return .localOnly
            }
            return (hasKnownNewerGap || !newerLiveEdgeReached) ? .remoteNewerPage : .endReached
        case .older:
            guard requestedWindow.minIndex < 0 else {
                return .localOnly
            }
            return isArchiveEnded ? .endReached : .remoteOlderPage
        }
    }

    static func fallbackDirectionForShortContentDrag(
        canLoadDatasource: Bool,
        gestureTranslationY: CGFloat,
        boundaryContext: ChatHistoryPagingBoundaryContext,
        currentPageMinIndex: Int,
        currentPageMaxIndex: Int,
        totalCount: Int,
        hasRemoteNewerAvailable: Bool = false
    ) -> ChatHistoryPageDirection? {
        guard canLoadDatasource,
              !boundaryContext.visibleRealSections.isEmpty else {
            return nil
        }

        let boundary = boundaryAvailability(
            boundaryContext: boundaryContext,
            currentPageMinIndex: currentPageMinIndex,
            currentPageMaxIndex: currentPageMaxIndex,
            totalCount: totalCount,
            hasRemoteNewerAvailable: hasRemoteNewerAvailable
        )

        return directionForBoundaryDrag(
            gestureTranslationY: gestureTranslationY,
            boundary: boundary
        )
    }
}

enum ChatBootstrapViewState: Equatable {
    case skeleton
    case content
    case empty

    static func resolve(
        messageCount: Int,
        isSynced: Bool,
        isInitialBootstrapInFlight: Bool,
        hasPendingInitialAnchorRequest: Bool,
        allowsStaleLocalHistory: Bool = false
    ) -> ChatBootstrapViewState {
        if hasPendingInitialAnchorRequest {
            return .skeleton
        }
        if allowsStaleLocalHistory && messageCount > 0 {
            return .content
        }
        if isInitialBootstrapInFlight {
            return .skeleton
        }
        if !isSynced {
            return .skeleton
        }
        if messageCount > 0 {
            return .content
        }
        return .empty
    }
}

enum ChatBootstrapLocalHistoryFallbackPolicy {
    static let fallbackDelay: TimeInterval = 10.0

    static func shouldScheduleFallback(
        messageCount: Int,
        isShowingSkeleton: Bool,
        allowsStaleLocalHistory: Bool,
        hasPendingInitialAnchorRequest: Bool
    ) -> Bool {
        messageCount > 0 &&
        isShowingSkeleton &&
        !allowsStaleLocalHistory &&
        !hasPendingInitialAnchorRequest
    }

    static func shouldRevealLocalHistory(
        messageCount: Int,
        isShowingSkeleton: Bool,
        hasPendingInitialAnchorRequest: Bool
    ) -> Bool {
        messageCount > 0 &&
        isShowingSkeleton &&
        !hasPendingInitialAnchorRequest
    }
}

enum ChatBootstrapSkeletonRenderPolicy {
    static func shouldRenderSkeletonDatasource(
        forceRender: Bool,
        isDatasourceEmpty: Bool,
        isShowingBootstrapPlaceholder: Bool
    ) -> Bool {
        forceRender || isDatasourceEmpty || !isShowingBootstrapPlaceholder
    }
}

enum ChatInitialHistoryAppearancePolicy {
    static func shouldStart(isShowingBootstrapPlaceholder: Bool) -> Bool {
        isShowingBootstrapPlaceholder
    }

    static func shouldFinish(itemCount: Int, containsOnlyFakeMessages: Bool) -> Bool {
        itemCount == 0 || !containsOnlyFakeMessages
    }

    static func shouldAnimateDatasourceApply(isInitialHistoryAppearancePending: Bool) -> Bool {
        !isInitialHistoryAppearancePending
    }

    static func shouldUseReloadFallbackForTargetedDiff(animated: Bool) -> Bool {
        !animated
    }

    static func shouldApplyFollowupChangesetAfterBootstrapReload(didReloadInitialWindow: Bool) -> Bool {
        !didReloadInitialWindow
    }

    static func shouldCompleteInitialAppearance(hasViewAppeared: Bool, hasRenderedStableHistory: Bool) -> Bool {
        hasViewAppeared && hasRenderedStableHistory
    }

    static func shouldForceNonAnimatedApplyForInitialPopulation(oldItemCount: Int, newItemCount: Int) -> Bool {
        oldItemCount == 0 && newItemCount > 0
    }
}

enum ChatDatasourceApplyMode {
    case fullReload(keepOffset: Bool = false)
    case windowReload(keepOffset: Bool = false)
    case targetedDiff
}

struct ChatDatasetApplyPlan {
    let window: ChatDatasetWindow
    let mode: ChatDatasourceApplyMode
    let invalidateLayout: Bool
}

struct ChatMessageContentUpdate: Equatable {
    let primary: String
    let indexPath: IndexPath
}

enum ChatMessageUpdateClassification: Equatable {
    case contentOnly
    case layout
}

struct ChatMessageLayoutSignature: Equatable {
    enum CellKind: Equatable {
        case text
        case system
        case sticker
        case initial
    }

    enum MessageKindKey: Equatable {
        case attributedText
        case emoji
        case sticker(String)
        case call(String)
        case system
        case initial
        case skeleton
        case date
        case unread
    }

    let cellKind: CellKind
    let messageKindKey: MessageKindKey
    let isOutgoing: Bool
    let withAuthor: Bool
    let withAvatar: Bool
    let tailed: Bool
    let hasIndicator: Bool
    let messageWarningText: String?
    let images: [String]
    let videos: [String]
    let files: [String]
    let audios: [String]
    let forwards: [ForwardSignature]

    struct ForwardSignature: Equatable {
        let primary: String
        let isOutgoing: Bool
        let images: [String]
        let videos: [String]
        let files: [String]
        let audios: [String]
        let subforwards: [ForwardSignature]

        init(_ attachment: MessageAttachment) {
            self.primary = attachment.primary
            self.isOutgoing = attachment.outgoing
            self.images = attachment.images.map(\.primary)
            self.videos = attachment.videos.map(\.primary)
            self.files = attachment.files.map(\.primary)
            self.audios = attachment.audios.map(\.primary)
            self.subforwards = attachment.subforwards.map(ForwardSignature.init)
        }
    }

    init(_ message: ChatViewController.Datasource) {
        self.cellKind = Self.cellKind(for: message.kind)
        self.messageKindKey = Self.messageKindKey(for: message.kind)
        self.isOutgoing = message.isOutgoing
        self.withAuthor = message.withAuthor
        self.withAvatar = message.withAvatar
        self.tailed = message.tailed
        self.hasIndicator = message.indicator != .none
        self.messageWarningText = message.messageWarningText
        self.images = message.images.map(\.primary)
        self.videos = message.videos.map(\.primary)
        self.files = message.files.map(\.primary)
        self.audios = message.audios.map(\.primary)
        self.forwards = message.forwards.map(ForwardSignature.init)
    }

    private static func cellKind(for kind: MessageKind) -> CellKind {
        switch kind {
        case .attributedText, .emoji, .skeleton:
            return .text
        case .system, .date, .unread, .call:
            return .system
        case .sticker:
            return .sticker
        case .initial:
            return .initial
        }
    }

    private static func messageKindKey(for kind: MessageKind) -> MessageKindKey {
        switch kind {
        case .attributedText:
            return .attributedText
        case .emoji:
            return .emoji
        case .sticker(let attachment):
            return .sticker(attachment.primary)
        case .call(let attachment):
            return .call(attachment.primary)
        case .system:
            return .system
        case .initial:
            return .initial
        case .skeleton:
            return .skeleton
        case .date:
            return .date
        case .unread:
            return .unread
        }
    }
}

enum ChatMessageUpdatePolicy {
    private static let sizeTolerance: CGFloat = 0.5

    static func shouldUseReloadFallback(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> Bool {
        old.hasDuplicateKeys || new.hasDuplicateKeys
    }

    static func classify(
        old oldMessage: ChatViewController.Datasource,
        new newMessage: ChatViewController.Datasource,
        oldSize: CGSize?,
        newSize: CGSize?
    ) -> ChatMessageUpdateClassification {
        guard oldMessage.primary == newMessage.primary else {
            return .layout
        }
        guard ChatMessageLayoutSignature(oldMessage) == ChatMessageLayoutSignature(newMessage) else {
            return .layout
        }
        guard let oldSize, let newSize, sizesAreEqual(oldSize, newSize) else {
            return .layout
        }
        return .contentOnly
    }

    static func shouldUpdateContent(
        old oldMessage: ChatViewController.Datasource,
        new newMessage: ChatViewController.Datasource
    ) -> Bool {
        !ChatViewController.Datasource.compareContent(oldMessage, newMessage) ||
        messageKindContentKey(oldMessage.kind) != messageKindContentKey(newMessage.kind) ||
        attributedTextKey(oldMessage.timeMarkerText) != attributedTextKey(newMessage.timeMarkerText) ||
        attachmentContentKey(oldMessage) != attachmentContentKey(newMessage)
    }

    private static func sizesAreEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= sizeTolerance &&
        abs(lhs.height - rhs.height) <= sizeTolerance
    }

    private static func messageKindContentKey(_ kind: MessageKind) -> String {
        switch kind {
        case .attributedText(let text):
            return "attributedText:\(attributedTextKey(text))"
        case .emoji(let text):
            return "emoji:\(text)"
        case .sticker(let attachment):
            return "sticker:\(attachment.primary):\(attachment.url?.absoluteString ?? ""):\(attachment.size)"
        case .call(let attachment):
            return "call:\(attachment.primary):\(attachment.incoming):\(attachment.missed)"
        case .system(let text):
            return "system:\(attributedTextKey(text))"
        case .initial(let text):
            return "initial:\(attributedTextKey(text))"
        case .skeleton(let text):
            return "skeleton:\(attributedTextKey(text))"
        case .date(let text):
            return "date:\(attributedTextKey(text))"
        case .unread(let text):
            return "unread:\(attributedTextKey(text))"
        }
    }

    private static func attributedTextKey(_ text: NSAttributedString?) -> String {
        guard let text else { return "" }
        return text.string
    }

    private static func attachmentContentKey(_ message: ChatViewController.Datasource) -> String {
        [
            message.images.map { "\($0.primary):\($0.url?.absoluteString ?? ""):\($0.size):\($0.isSensitive):\($0.isSensitiveRevealed)" }.joined(separator: "|"),
            message.videos.map { "\($0.primary):\($0.url?.absoluteString ?? ""):\($0.previewUrl?.absoluteString ?? ""):\($0.size):\($0.duration):\($0.downloaded):\($0.isSensitive):\($0.isSensitiveRevealed)" }.joined(separator: "|"),
            message.files.map { "\($0.primary):\($0.url?.absoluteString ?? ""):\($0.name):\($0.size):\($0.downloaded)" }.joined(separator: "|"),
            message.audios.map { "\($0.primary):\($0.url?.absoluteString ?? ""):\($0.duration):\($0.downloaded):\(pcmKey($0.pcm))" }.joined(separator: "|"),
            message.forwards.map(forwardContentKey(_:)).joined(separator: "|")
        ].joined(separator: "#")
    }

    private static func forwardContentKey(_ attachment: MessageAttachment) -> String {
        [
            attachment.primary,
            attachment.author,
            attachment.outgoing.description,
            attributedTextKey(attachment.textMessage),
            attributedTextKey(attachment.timeMarker),
            attachment.images.map { "\($0.primary):\($0.url?.absoluteString ?? ""):\($0.size):\($0.isSensitive):\($0.isSensitiveRevealed)" }.joined(separator: "|"),
            attachment.videos.map { "\($0.primary):\($0.url?.absoluteString ?? ""):\($0.previewUrl?.absoluteString ?? ""):\($0.size):\($0.duration):\($0.downloaded):\($0.isSensitive):\($0.isSensitiveRevealed)" }.joined(separator: "|"),
            attachment.files.map { "\($0.primary):\($0.url?.absoluteString ?? ""):\($0.name):\($0.size):\($0.downloaded)" }.joined(separator: "|"),
            attachment.audios.map { "\($0.primary):\($0.url?.absoluteString ?? ""):\($0.duration):\($0.downloaded):\(pcmKey($0.pcm))" }.joined(separator: "|"),
            attachment.subforwards.map(forwardContentKey(_:)).joined(separator: "|")
        ].joined(separator: "#")
    }

    private static func pcmKey(_ pcm: [Float]) -> String {
        pcm.map { String(format: "%.3f", $0) }.joined(separator: ",")
    }
}

struct ChatDatasourceCoordinator {
    struct DiffResult {
        let inserts: IndexSet
        let deletes: IndexSet
        let reloads: [IndexPath]
        let contentOnlyUpdates: [ChatMessageContentUpdate]
        let moves: [(from: IndexPath, to: IndexPath)]

        var isEmpty: Bool {
            inserts.isEmpty && deletes.isEmpty && reloads.isEmpty && contentOnlyUpdates.isEmpty && moves.isEmpty
        }

        var hasCollectionUpdates: Bool {
            !inserts.isEmpty || !deletes.isEmpty || !reloads.isEmpty || !moves.isEmpty
        }
    }

    static func makeSnapshot(items: [ChatViewController.Datasource]) -> ChatDatasourceSnapshot {
        ChatDatasourceSnapshot(items: items)
    }

    static func diff(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> DiffResult {
        diff(old: old, new: new, oldSizeProvider: nil, newSizeProvider: nil)
    }

    static func diff(
        old: ChatDatasourceSnapshot,
        new: ChatDatasourceSnapshot,
        oldSizeProvider: ((ChatViewController.Datasource) -> CGSize?)?,
        newSizeProvider: ((ChatViewController.Datasource) -> CGSize?)?
    ) -> DiffResult {
        let changes = DeepDiff.diff(old: old.items, new: new.items)
        let inserts = IndexSet(changes.compactMap { $0.insert?.index })
        let deletes = IndexSet(changes.compactMap { $0.delete?.index })
        let moves = changes.compactMap { change -> (from: IndexPath, to: IndexPath)? in
            guard let move = change.move else { return nil }
            return (IndexPath(row: 0, section: move.fromIndex), IndexPath(row: 0, section: move.toIndex))
        }

        var contentOnlyUpdates: [ChatMessageContentUpdate] = []
        var reloads: [IndexPath] = []
        var handledSections = Set<Int>()

        changes.compactMap(\.replace).forEach { replace in
            handledSections.insert(replace.index)
        }

        let commonCount = min(old.items.count, new.items.count)
        for index in 0..<commonCount {
            guard !deletes.contains(index), !inserts.contains(index) else { continue }
            let oldItem = old.items[index]
            let newItem = new.items[index]
            guard oldItem.primary == newItem.primary else { continue }
            guard handledSections.contains(index) ||
                    ChatMessageUpdatePolicy.shouldUpdateContent(old: oldItem, new: newItem) else {
                continue
            }

            let indexPath = IndexPath(row: 0, section: index)
            let classification = ChatMessageUpdatePolicy.classify(
                old: oldItem,
                new: newItem,
                oldSize: oldSizeProvider?(oldItem),
                newSize: newSizeProvider?(newItem)
            )
            switch classification {
            case .contentOnly:
                contentOnlyUpdates.append(ChatMessageContentUpdate(primary: newItem.primary, indexPath: indexPath))
            case .layout:
                reloads.append(indexPath)
            }
        }

        return DiffResult(
            inserts: inserts,
            deletes: deletes,
            reloads: reloads,
            contentOnlyUpdates: contentOnlyUpdates,
            moves: moves
        )
    }

    static func compatibleForTargetedApply(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> Bool {
        guard !old.items.isEmpty else { return false }
        guard old.items.count == new.items.count else { return false }
        guard !old.hasDuplicateKeys, !new.hasDuplicateKeys else { return false }
        return zip(old.items, new.items).allSatisfy { $0.primary == $1.primary }
    }

    static func supportsTargetedApply(old: ChatDatasourceSnapshot, new: ChatDatasourceSnapshot) -> Bool {
        !old.items.isEmpty && !ChatMessageUpdatePolicy.shouldUseReloadFallback(old: old, new: new)
    }
}

struct ChatDatasetCoordinator {
    let pageSize: Int

    func clamp(_ window: ChatDatasetWindow, totalCount: Int) -> ChatDatasetWindow {
        guard totalCount > 0 else { return .empty }

        var minIndex = max(0, window.minIndex)
        var maxIndex = min(totalCount, max(minIndex, window.maxIndex))

        if maxIndex == minIndex {
            maxIndex = min(totalCount, minIndex + pageSize)
            minIndex = max(0, maxIndex - pageSize)
        }

        return ChatDatasetWindow(minIndex: minIndex, maxIndex: maxIndex)
    }

    func initialWindow(totalCount: Int) -> ChatDatasetWindow {
        clamp(ChatDatasetWindow(minIndex: totalCount - pageSize, maxIndex: totalCount), totalCount: totalCount)
    }

    func replacementWindow(around index: Int, totalCount: Int) -> ChatDatasetWindow {
        let halfPage = pageSize / 2
        return clamp(ChatDatasetWindow(minIndex: index - halfPage, maxIndex: index + halfPage), totalCount: totalCount)
    }

    func nextWindow(from current: ChatDatasetWindow, direction: ChatHistoryPageDirection) -> ChatDatasetWindow {
        switch direction {
        case .newer:
            return ChatDatasetWindow(minIndex: current.minIndex, maxIndex: current.maxIndex + pageSize)
        case .older:
            return ChatDatasetWindow(minIndex: current.minIndex - pageSize, maxIndex: current.maxIndex)
        }
    }

    func visibleWindow(currentPage: ChatViewController.ChatPage) -> ChatDatasetWindow {
        ChatDatasetWindow(minIndex: currentPage.minIndex, maxIndex: currentPage.maxIndex)
    }
}

extension ChatViewController {
    internal static let attachmentTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    internal static func mapReferenceAttachments(
        _ references: [MessageReferenceStorageItem],
        revealedSensitiveMediaPrimaries: Set<String> = Set<String>()
    ) -> (images: [ImageAttachment], videos: [VideoAttachment], audio: [AudioAttachment], files: [FileAttachment]) {
        var images: [ImageAttachment] = []
        var videos: [VideoAttachment] = []
        var audio: [AudioAttachment] = []
        var files: [FileAttachment] = []

        references.filter { !$0.isLocallyHiddenByReport }.forEach { item in
            let mediaType = SensitiveMediaAnalysisService.sensitiveAnalyzableMediaType(
                kind: item.kind,
                mimeType: item.mimeType,
                mediaType: item.metadata?["media-type"] as? String
            )
            switch mediaType {
            case .image:
                images.append(ImageAttachment(
                    primary: item.primary,
                    url: item.downloadUrl ?? item.videoPreviewUrl,
                    size: item.sizeInPx ?? CGSize(square: 128),
                    isSensitive: item.isSensitive,
                    isSensitiveRevealed: revealedSensitiveMediaPrimaries.contains(item.primary)
                ))
            case .video:
                videos.append(VideoAttachment(
                    primary: item.primary,
                    url: item.downloadUrl,
                    size: item.sizeInPx ?? CGSize(square: 128),
                    previewUrl: item.videoPreviewUrl,
                    duration: 0,
                    downloaded: item.isDownloaded,
                    isSensitive: item.isSensitive,
                    isSensitiveRevealed: revealedSensitiveMediaPrimaries.contains(item.primary)
                ))
            case .unsupported:
                if item.kind_ == "voice" {
                    audio.append(AudioAttachment(primary: item.primary, url: item.decodedUrl, size: 10, name: "name", duration: Double(item.duration ?? 0), downloaded: item.isDownloaded, pcm: item.meteringLevels ?? []))
                } else if item.kind == .media && MimeIcon(item.mimeType).value != .audio && item.kind_ != "groupchat" {
                    files.append(FileAttachment(primary: item.primary, url: item.downloadUrl, size: Double(item.sizeInBytesRaw), name: item.filename ?? item.name ?? "file", downloaded: item.isDownloaded))
                }
            }
        }

        return (images, videos, audio, files)
    }
    
    internal func willUpdateFloatingDate() {
        self.updateFloatingDateObserverSignal.accept(true)
    }
    
    internal func updateFloatingDate() {
        guard let topVisibleReasonableMessageIndex = self.messagesCollectionView.indexPathsForVisibleItems.compactMap ({
            return $0.section
        }).min() else {
            return
        }
        let pinnOffset: CGFloat = 0//54
//        if let topInset = (UIApplication.shared.delegate as? AppDelegate)?.window?.safeAreaInsets.top {
//            pinnOffset += topInset
//        }
        let frame = CGRect(
            origin: CGPoint(
                x: 0,
                y: pinnOffset
            ),
            size: CGSize(
                width: self.view.bounds.width,
                height: 34
            )
        )
        let index = [topVisibleReasonableMessageIndex, self.datasource.count - 1].min() ?? 0
        if self.datasource.count < 5 {
            self.pinnedDateView.isHidden = true
//            self.pinnedDateView.hide()
        } else {
//            self.pinnedDateView.show()
            self.pinnedDateView.isHidden = false
            let text = NSAttributedString(
                string: sectionsDateFormatter.string(from: self.datasource[index].sentDate),
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: UIColor.white,
                ]
            )
            self.pinnedDateView.frame = frame
            self.pinnedDateView.configure(text)
        }
    }
    
    internal func mapAttachment(_ attachment: MessageForwardsInlineStorageItem) -> MessageAttachment {
        let references = attachment.references.toArray()
        let mappedReferences = Self.mapReferenceAttachments(references, revealedSensitiveMediaPrimaries: self.revealedSensitiveMediaPrimaries)
        let timeString = Self.attachmentTimeFormatter.string(from: attachment.originalDate ?? Date())
        let timeMarkerString = NSAttributedString(
            string: timeString,
            attributes: [
                NSAttributedString.Key.foregroundColor: UIColor(red: 158.0 / 255.0, green: 158.0 / 255.0, blue: 158.0 / 255.0, alpha: 1),
                NSAttributedString.Key.font: UIFont.systemFont(ofSize: 10, weight: .regular)
            ]
        )
        return MessageAttachment(
            primary: attachment.primary,
            author: attachment.tryToLoadNickname(),
            jid: attachment.forwardJid,
            outgoing: attachment.isOutgoing,
            textMessage: attachment.createRefBody(
                [
                    NSAttributedString.Key.foregroundColor: UIColor.label,
                    NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .body)//UIFont.systemFont(ofSize: 16, weight: .regular),
                ],
                searchedText: self.searchTextObserver.value,
                searchedTextColor: .systemGreen
            ),
            images: mappedReferences.images,
            videos: mappedReferences.videos,
            files: mappedReferences.files,
            audios: mappedReferences.audio,
            timeMarker: timeMarkerString,
            subforwards: attachment.subforwards.toArray().compactMap({ return mapAttachment($0) })
        )
    }

    internal func applyChatDatasource(
        _ items: [Datasource],
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        let newSnapshot = ChatDatasourceCoordinator.makeSnapshot(items: items)
        let previousSnapshot = datasourceSnapshot
        let containsOnlyFakeMessages = !items.isEmpty && items.allSatisfy(\.isFakeMessage)
        let shouldAutoScrollToBottom = self.isNearBottom()
            && !ChatInitialScrollPolicy.shouldDeferDefaultScroll(
                hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
                isAnchorNavigationInFlight: self.isMessageAnchorNavigationInFlight
            )
            && !containsOnlyFakeMessages
        let shouldAnimateApply = animated && !ChatInitialHistoryAppearancePolicy.shouldForceNonAnimatedApplyForInitialPopulation(
            oldItemCount: previousSnapshot.items.count,
            newItemCount: newSnapshot.items.count
        )

        let finish: () -> Void = {
            if invalidateLayout {
                self.messagesCollectionView.collectionViewLayout.invalidateLayout()
                self.messagesCollectionView.layoutIfNeeded()
            }
            self.messagesCollectionView.layoutIfNeeded()
            self.updateChatCollectionInsets()
            if shouldAutoScrollToBottom {
                self.scrollToBottom(animated: shouldAnimateApply)
            }
            completion?()
            self.refreshUnreadMentionsNavigatorState()
            self.updateVisibleVoiceMessageQueue()
            if self.initialHistoryAppearancePending,
               ChatInitialHistoryAppearancePolicy.shouldFinish(itemCount: items.count, containsOnlyFakeMessages: containsOnlyFakeMessages) {
                self.hasRenderedStableInitialHistory = true
                self.finishInitialHistoryAppearanceIfPossible()
            }
        }

        let runWithoutAnimation: (@escaping () -> Void) -> Void = { updates in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let wereAnimationsEnabled = UIView.areAnimationsEnabled
            UIView.setAnimationsEnabled(false)
            UIView.performWithoutAnimation {
                updates()
                self.messagesCollectionView.layoutIfNeeded()
                self.messagesCollectionView.layer.removeAllAnimations()
                self.messagesCollectionView.visibleCells.forEach {
                    $0.layer.removeAllAnimations()
                    $0.contentView.layer.removeAllAnimations()
                }
            }
            UIView.setAnimationsEnabled(wereAnimationsEnabled)
            CATransaction.commit()
        }

        switch mode {
        case .fullReload(let keepOffset):
            self.datasource = items
            self.datasourceSnapshot = newSnapshot
            let updates = {
                if keepOffset {
                    self.messagesCollectionView.reloadDataAndKeepOffset()
                } else {
                    self.messagesCollectionView.reloadData()
                }
            }
            if shouldAnimateApply {
                updates()
            } else {
                runWithoutAnimation(updates)
            }
            finish()
        case .windowReload(let keepOffset):
            self.datasource = items
            self.datasourceSnapshot = newSnapshot
            let updates = {
                if keepOffset {
                    self.messagesCollectionView.reloadDataAndKeepOffset()
                } else {
                    self.messagesCollectionView.reloadData()
                }
            }
            if shouldAnimateApply {
                updates()
            } else {
                runWithoutAnimation(updates)
            }
            finish()
        case .targetedDiff:
            if previousSnapshot.items.isEmpty {
                self.datasource = items
                self.datasourceSnapshot = newSnapshot
                runWithoutAnimation {
                    self.messagesCollectionView.reloadData()
                }
                finish()
                return
            }

            guard ChatDatasourceCoordinator.supportsTargetedApply(old: previousSnapshot, new: newSnapshot) else {
                self.datasource = items
                self.datasourceSnapshot = newSnapshot
                if shouldAnimateApply {
                    self.messagesCollectionView.reloadData()
                } else {
                    runWithoutAnimation {
                        self.messagesCollectionView.reloadData()
                    }
                }
                finish()
                return
            }

            let flowLayout = self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout
            let diff = ChatDatasourceCoordinator.diff(
                old: previousSnapshot,
                new: newSnapshot,
                oldSizeProvider: { flowLayout?.sizeForMessage($0) },
                newSizeProvider: { flowLayout?.sizeForMessage($0) }
            )
            self.datasource = items
            self.datasourceSnapshot = newSnapshot

            guard !diff.isEmpty else {
                finish()
                return
            }

            let applyContentOnlyUpdates = {
                diff.contentOnlyUpdates.forEach { update in
                    self.updateVisibleMessageContent(primary: update.primary)
                }
            }

            let applyLayoutUpdates = {
                guard !diff.reloads.isEmpty else { return }
                diff.reloads.forEach { indexPath in
                    guard indexPath.section < items.count else { return }
                    flowLayout?.invalidateLastMessageCachedSize(primary: items[indexPath.section].primary)
                }
                self.messagesCollectionView.reconfigureItems(at: diff.reloads)
            }

            let finishAfterNonStructuralUpdates = {
                runWithoutAnimation {
                    applyLayoutUpdates()
                    applyContentOnlyUpdates()
                }
                finish()
            }

            guard diff.hasCollectionUpdates else {
                finishAfterNonStructuralUpdates()
                return
            }

            let updates = {
                let batchUpdates = {
                    if !diff.deletes.isEmpty {
                        self.messagesCollectionView.deleteSections(diff.deletes)
                    }
                    if !diff.inserts.isEmpty {
                        self.messagesCollectionView.insertSections(diff.inserts)
                    }
                    diff.moves.forEach {
                        self.messagesCollectionView.moveSection($0.from.section, toSection: $0.to.section)
                    }
                }
                if shouldAnimateApply {
                    self.messagesCollectionView.performBatchUpdates(batchUpdates, completion: { _ in
                        finishAfterNonStructuralUpdates()
                    })
                } else {
                    runWithoutAnimation {
                        self.messagesCollectionView.performBatchUpdates(batchUpdates, completion: { _ in
                            finishAfterNonStructuralUpdates()
                        })
                    }
                }
            }
            updates()
        }
    }

    @discardableResult
    internal func updateVisibleMessageContent(primary: String) -> Bool {
        guard let section = datasourceSnapshot.primaryIndex[primary],
              section < datasource.count else {
            return false
        }

        let indexPath = IndexPath(row: 0, section: section)
        guard let cell = messagesCollectionView.cellForItem(at: indexPath) as? MessageCollectionViewCell else {
            return false
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let wereAnimationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        UIView.performWithoutAnimation {
            cell.reconfigureContent(with: datasource[section], at: indexPath, and: messagesCollectionView)
            cell.setNeedsLayout()
            cell.layoutIfNeeded()
            cell.layer.removeAllAnimations()
            cell.contentView.layer.removeAllAnimations()
        }
        UIView.setAnimationsEnabled(wereAnimationsEnabled)
        CATransaction.commit()
        return true
    }

    internal var datasetCoordinator: ChatDatasetCoordinator {
        ChatDatasetCoordinator(pageSize: self.datasourcePageSize)
    }

    internal func syncCurrentPage(with window: ChatDatasetWindow) {
        self.currentPage.minIndex = window.minIndex
        self.currentPage.maxIndex = window.maxIndex
    }

    internal func visibleWindow() -> ChatDatasetWindow {
        self.datasetCoordinator.visibleWindow(currentPage: self.currentPage)
    }

    internal func sliceForWindow(_ window: ChatDatasetWindow) -> [MessageStorageItem] {
        guard self.messagesObserver != nil else { return [] }
        let normalized = self.datasetCoordinator.clamp(window, totalCount: self.messagesObserver.count)
        guard normalized.count > 0 else { return [] }
        return Array(self.messagesObserver.prefix(upTo: normalized.maxIndex).suffix(normalized.count)).map { $0.freeze() }
    }

    internal func ensureObserverLookupMaps(force: Bool = false) {
        guard self.messagesObserver != nil else {
            self.observerPrimaryIndexMap = [:]
            self.observerArchivedIdIndexMap = [:]
            self.observerMessageIdIndexMap = [:]
            self.observerOldestArchivedId = nil
            self.observerNewestArchivedId = nil
            self.observerLookupSignature = nil
            return
        }

        let signature = ObserverLookupSignature(
            count: self.messagesObserver.count,
            firstPrimary: self.messagesObserver.first?.primary,
            lastPrimary: self.messagesObserver.last?.primary
        )

        guard force || self.observerLookupSignature != signature else {
            return
        }

        let lookupMaps = ChatObserverLookupPolicy.build(from: self.messagesObserver)
        self.observerPrimaryIndexMap = lookupMaps.primaryIndex
        self.observerArchivedIdIndexMap = lookupMaps.archivedIdIndex
        self.observerMessageIdIndexMap = lookupMaps.messageIdIndex
        self.observerOldestArchivedId = lookupMaps.oldestArchivedId
        self.observerNewestArchivedId = lookupMaps.newestArchivedId
        self.observerLookupSignature = signature
    }

    internal func setArchiveLoading(_ isLoading: Bool) {
        DispatchQueue.main.async {
            self.messageLoadingActivityIndicator.isHidden = !isLoading
        }
    }

    internal func oldestObservedArchivedId(persistedCursorId: String? = nil) -> String? {
        guard self.messagesObserver != nil else { return nil }
        self.ensureObserverLookupMaps()
        return self.observerOldestArchivedId ?? persistedCursorId ?? self.persistedHistoryCursorId()
    }

    internal func observedOldestArchivedId() -> String? {
        guard self.messagesObserver != nil else { return nil }
        self.ensureObserverLookupMaps()
        return self.observerOldestArchivedId
    }

    internal func observedNewestArchivedId() -> String? {
        guard self.messagesObserver != nil else { return nil }
        self.ensureObserverLookupMaps()
        return self.observerNewestArchivedId
    }

    internal func authoritativeOlderPagingCursorId(persistedCursorId: String? = nil) -> String? {
        if let persistedCursorId, persistedCursorId.isNotEmpty {
            return persistedCursorId
        }
        return self.observedOldestArchivedId()
    }

    internal func authoritativeNewerPagingCursorId(persistedCursorId: String? = nil) -> String? {
        if let persistedCursorId, persistedCursorId.isNotEmpty {
            return persistedCursorId
        }
        return self.observedNewestArchivedId()
    }

    internal func currentGroupchatMemberId(in realm: Realm? = nil) -> String? {
        let resolve: (Realm) -> String? = { realm in
            guard self.conversationType == .group else {
                return nil
            }

            return MentionNotificationSync.currentGroupMemberId(
                owner: self.owner,
                groupchatJid: self.jid,
                in: realm
            )
        }

        if let realm {
            return resolve(realm)
        }

        do {
            return resolve(try WRealm.safe())
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    internal func unreadMentionHintArchivedId() -> String? {
        do {
            let realm = try WRealm.safe()
            return realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            )?.mentionId
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    internal func visibleRealMessagePrimaries() -> Set<String> {
        Set(
            self.messagesCollectionView.indexPathsForVisibleItems.compactMap {
                guard $0.section >= 0,
                      $0.section < self.datasource.count else {
                    return nil
                }
                let item = self.datasource[$0.section]
                return item.isFakeMessage ? nil : item.primary
            }
        )
    }

    internal func rebuildUnreadMentionItems() {
        guard self.conversationType == .group,
              self.messagesObserver != nil else {
            self.unreadMentionItems = []
            self.unreadMentionsState = .empty
            self.currentUnreadMentionNotificationPrimary = nil
            return
        }

        do {
            let realm = try WRealm.safe()
            self.ensureObserverLookupMaps()
            let currentMemberId = self.currentGroupchatMemberId(in: realm)
            let notifications = realm.objects(NotificationStorageItem.self)
                .filter("owner == %@ AND category_ == %@", self.owner, XMPPNotificationsManager.Category.mention.rawValue)

            let chatPrimary = LastChatsStorageItem.genPrimary(
                jid: self.jid,
                owner: self.owner,
                conversationType: self.conversationType
            )
            let notificationBackedItems = ChatUnreadMentionIndexPolicy.rebuild(
                from: notifications,
                messagesObserver: self.messagesObserver,
                observerLookupMaps: ChatObserverLookupPolicy.build(from: self.messagesObserver),
                in: realm,
                chatPrimary: chatPrimary,
                currentMemberId: currentMemberId,
                groupchatJid: self.jid
            )
            self.unreadMentionItems = notificationBackedItems
            if self.unreadMentionItems.isEmpty,
               let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: chatPrimary),
               let fallbackItem = ChatUnreadMentionFallbackPolicy.fallbackItem(
                mentionId: chat.mentionId,
                chatPrimary: chatPrimary,
                currentMemberId: currentMemberId,
                groupchatJid: self.jid,
                date: chat.messageDate == Date(timeIntervalSince1970: 0) ? Date() : chat.messageDate
               ) {
                self.unreadMentionItems = [fallbackItem]
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            self.unreadMentionItems = []
            self.unreadMentionsState = .empty
            self.currentUnreadMentionNotificationPrimary = nil
        }
    }

    internal func refreshUnreadMentionsNavigatorState(animated: Bool = false) {
        guard !self.showSkeletonObserver.value else {
            self.unreadMentionsState = .empty
            self.currentUnreadMentionNotificationPrimary = nil
            self.scheduleVisibleUnreadMentionReconciliation(notificationPrimaries: [])
            if self.shouldShowUnreadMentionsNavigator.value {
                self.shouldShowUnreadMentionsNavigator.accept(false)
            } else {
                self.updateUnreadMentionsNavigatorFrame(animated: animated)
                self.updateScrollDownButtonFrame(animated: animated)
            }
            return
        }

        self.ensureObserverLookupMaps()
        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: self.unreadMentionItems,
            observerPrimaryIndexMap: self.observerPrimaryIndexMap,
            visiblePrimaries: self.visibleRealMessagePrimaries(),
            preferredArchivedId: self.unreadMentionHintArchivedId(),
            selectedNotificationPrimary: self.currentUnreadMentionNotificationPrimary
        )
        self.unreadMentionsState = state
        self.currentUnreadMentionNotificationPrimary = state.currentTarget?.notificationPrimary
        self.unreadMentionsNavigatorView.update(
            mode: state.mode,
            unreadCount: state.unreadCount,
            accentColor: self.accountPallete.tint500
        )
        self.scheduleVisibleUnreadMentionReconciliation(notificationPrimaries: state.visibleUnreadNotificationPrimaries)

        let shouldShowNavigator = ChatUnreadMentionFloatingControlPolicy.shouldShowNavigator(
            conversationType: self.conversationType,
            unreadCount: state.unreadCount,
            isSearchMode: self.inSearchMode.value
        )

        if self.shouldShowUnreadMentionsNavigator.value != shouldShowNavigator {
            self.shouldShowUnreadMentionsNavigator.accept(shouldShowNavigator)
        } else {
            self.updateUnreadMentionsNavigatorFrame(animated: animated)
            self.updateScrollDownButtonFrame(animated: animated)
        }
    }

    internal func scheduleVisibleUnreadMentionReconciliation(notificationPrimaries: Set<String>) {
        self.visibleUnreadMentionReconciliationWorkItem?.cancel()
        guard !notificationPrimaries.isEmpty else {
            self.visibleUnreadMentionReconciliationWorkItem = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.markVisibleUnreadMentionNotificationsRead(Array(notificationPrimaries))
        }
        self.visibleUnreadMentionReconciliationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func markVisibleUnreadMentionNotificationsRead(_ notificationPrimaries: [String]) {
        guard notificationPrimaries.isNotEmpty else {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let realm = try WRealm.safe()
                var messagePrimariesToMarkRead: Set<String> = []
                var didChangeReadState = false

                try realm.write {
                    notificationPrimaries.forEach { primary in
                        guard let notification = realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: primary),
                              !notification.isRead,
                              notification.isMentionNotification,
                              notification.sourceChatJid == self.jid else {
                            return
                        }

                        notification.isRead = true
                        didChangeReadState = true
                        let result = MentionNotificationSync.reconcile(notification: notification, in: realm)
                        if let messagePrimary = result.linkedMessagePrimaryToMarkRead,
                           messagePrimary.isNotEmpty {
                            messagePrimariesToMarkRead.insert(messagePrimary)
                        }
                    }

                    MentionNotificationSync.refreshLastChatMentionIds(
                        owner: self.owner,
                        groupchatJids: [self.jid],
                        in: realm
                    )
                }

                guard didChangeReadState else {
                    return
                }

                messagePrimariesToMarkRead.forEach {
                    AccountManager.shared.find(for: self.owner)?.messages.readMessage($0, last: false)
                }

                DispatchQueue.main.async {
                    self.rebuildUnreadMentionItems()
                    self.refreshUnreadMentionsNavigatorState(animated: true)
                }
            } catch {
                DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            }
        }
    }

    internal func loadChatArchiveStateSnapshot() -> ChatArchiveStateSnapshot {
        let primaryKey = LastChatsStorageItem.genPrimary(
            jid: self.jid,
            owner: self.owner,
            conversationType: self.conversationType
        )
        do {
            let realm = try WRealm.safe()
            let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: primaryKey
            )
            let regularArchiveState = self.conversationType == .regular
                ? realm.object(
                    ofType: RegularChatArchiveSyncStateStorageItem.self,
                    forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(jid: self.jid, owner: self.owner)
                )
                : nil
            let persistedCursorId = chat?.lastLoadedMessageHistoryId?.isNotEmpty == true ? chat?.lastLoadedMessageHistoryId : nil
            return ChatArchiveStateSnapshot(
                primaryKey: primaryKey,
                persistedCursorId: regularArchiveState?.oldestLoadedArchiveId ?? persistedCursorId,
                fullArchiveLoaded: regularArchiveState?.olderArchiveEndReached ?? chat?.fullArchiveLoaded ?? false,
                newestCursorId: regularArchiveState?.newestLoadedArchiveId,
                newerLiveEdgeReached: regularArchiveState?.newerLiveEdgeReached ?? true,
                hasKnownNewerGap: regularArchiveState?.knownGaps.isNotEmpty ?? false
            )
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return ChatArchiveStateSnapshot(
                primaryKey: primaryKey,
                persistedCursorId: nil,
                fullArchiveLoaded: false
            )
        }
    }

    internal func persistedHistoryCursorId() -> String? {
        self.loadChatArchiveStateSnapshot().persistedCursorId
    }

    @discardableResult
    internal func applyChatArchiveStateIfNeeded(
        snapshot: ChatArchiveStateSnapshot,
        plan: ChatArchiveStateMutationPlan
    ) -> ChatArchiveStateSnapshot {
        let updatedSnapshot = ChatArchiveStateSnapshot(
            primaryKey: snapshot.primaryKey,
            persistedCursorId: plan.resolvedCursorId,
            fullArchiveLoaded: plan.fullArchiveLoaded,
            newestCursorId: snapshot.newestCursorId,
            newerLiveEdgeReached: snapshot.newerLiveEdgeReached,
            hasKnownNewerGap: snapshot.hasKnownNewerGap
        )

        guard plan.needsWrite else {
            return updatedSnapshot
        }

        do {
            let realm = try WRealm.safe()
            guard let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: snapshot.primaryKey
            ) else {
                return snapshot
            }
            try realm.write {
                if chat.isInvalidated { return }
                if plan.shouldWriteCursor {
                    chat.lastLoadedMessageHistoryId = plan.resolvedCursorId
                }
                if plan.shouldWriteFullArchiveLoaded {
                    chat.fullArchiveLoaded = plan.fullArchiveLoaded
                }
                if self.conversationType == .regular,
                   let regularState = realm.object(
                    ofType: RegularChatArchiveSyncStateStorageItem.self,
                    forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(jid: self.jid, owner: self.owner)
                   ) {
                    if plan.shouldWriteCursor {
                        regularState.oldestLoadedArchiveId = plan.resolvedCursorId
                    }
                    if plan.shouldWriteFullArchiveLoaded {
                        regularState.olderArchiveEndReached = plan.fullArchiveLoaded
                    }
                    regularState.updatedAt = Date()
                }
            }
            return updatedSnapshot
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return snapshot
        }
    }

    internal func isFullArchiveLoaded() -> Bool {
        self.loadChatArchiveStateSnapshot().fullArchiveLoaded
    }

    internal func setFullArchiveLoaded(_ isLoaded: Bool) {
        do {
            let realm = try WRealm.safe()
            if let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            ) {
                guard chat.fullArchiveLoaded != isLoaded else { return }
                try realm.write {
                    if chat.isInvalidated { return }
                    chat.fullArchiveLoaded = isLoaded
                    if self.conversationType == .regular {
                        let regularState = RegularChatArchiveSyncStateStorageItem.ensure(owner: self.owner, jid: self.jid, in: realm)
                        regularState.olderArchiveEndReached = isLoaded
                        regularState.updatedAt = Date()
                    }
                }
            }
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }

    internal func pagingBoundaryContext(visibleSections: [Int]) -> ChatHistoryPagingBoundaryContext {
        let visibleRealSections = Array(Set(visibleSections.filter {
            $0 >= 0 &&
            $0 < self.datasource.count &&
            !self.datasource[$0].isFakeMessage
        })).sorted()

        return ChatHistoryPagingBoundaryContext(
            firstRealSection: self.datasource.firstIndex(where: { !$0.isFakeMessage }),
            lastRealSection: self.datasource.lastIndex(where: { !$0.isFakeMessage }),
            visibleRealSections: visibleRealSections
        )
    }

    internal func beginInitialBootstrapTracking(queryId: String) {
        self.cancelInitialBootstrapLocalHistoryFallback()
        self.initialBootstrapQueryId = queryId
        self.isInitialBootstrapInFlight = true
        self.didReceiveInitialBootstrapEndPage = false
        self.initialBootstrapResultCount = nil
        self.initialBootstrapPersistedMessageCount = nil
        self.didEnterInitialBootstrapObserverSettlePhase = false
        self.didObserveInitialBootstrapPostIdleTick = false
    }

    internal func resetInitialBootstrapTracking() {
        self.cancelInitialBootstrapLocalHistoryFallback()
        self.initialBootstrapQueryId = nil
        self.isInitialBootstrapInFlight = false
        self.didReceiveInitialBootstrapEndPage = false
        self.initialBootstrapResultCount = nil
        self.initialBootstrapPersistedMessageCount = nil
        self.didEnterInitialBootstrapObserverSettlePhase = false
        self.didObserveInitialBootstrapPostIdleTick = false
    }

    @discardableResult
    internal func completeInitialBootstrapIfNeeded() -> Bool {
        guard self.isInitialBootstrapInFlight else {
            return false
        }

        let queryId = self.initialBootstrapQueryId
        let hasMessages = (self.messagesObserver?.count ?? 0) > 0
        let didConfirmEmpty = self.initialBootstrapResultCount == 0
        let isMessagePipelineIdle = queryId.flatMap {
            AccountManager.shared.find(for: self.owner)?.messages.hasPendingMessages(forQueryId: $0)
        }.map { !$0 } ?? true

        let requiresObserverSettle = (self.initialBootstrapPersistedMessageCount ?? 0) > 0
        if self.didReceiveInitialBootstrapEndPage,
           isMessagePipelineIdle,
           requiresObserverSettle,
           !self.didEnterInitialBootstrapObserverSettlePhase {
            self.didEnterInitialBootstrapObserverSettlePhase = true
            DispatchQueue.main.async {
                self.didObserveInitialBootstrapPostIdleTick = true
                _ = self.completeInitialBootstrapIfNeeded()
            }
            return false
        }

        guard ChatInitialBootstrapCompletionPolicy.shouldFinish(
            didReceiveEndPage: self.didReceiveInitialBootstrapEndPage,
            hasMessages: hasMessages,
            didConfirmEmpty: didConfirmEmpty,
            isMessagePipelineIdle: isMessagePipelineIdle,
            requiresObserverSettle: requiresObserverSettle,
            didObservePostIdleTick: self.didObserveInitialBootstrapPostIdleTick
        ) else {
            return false
        }

        let snapshot = self.loadChatArchiveStateSnapshot()
        let resolvedCursorId = ChatArchiveStateMutationPolicy.resolveCursorId(
            observedCursorId: self.observedOldestArchivedId(),
            transportFirst: "",
            transportLast: "",
            currentPersistedCursorId: snapshot.persistedCursorId
        )
        let plan = ChatArchiveStateMutationPolicy.resolvePlan(
            snapshot: snapshot,
            resolvedCursorId: resolvedCursorId,
            nextFullArchiveLoaded: snapshot.fullArchiveLoaded
        )
        _ = self.applyChatArchiveStateIfNeeded(snapshot: snapshot, plan: plan)
        self.rebuildUnreadMentionItems()
        self.resetInitialBootstrapTracking()
        if hasMessages {
            self.allowsStaleLocalHistoryDuringInitialBootstrap = true
        }
        self.applyBootstrapViewState(self.currentBootstrapViewState(), forceRender: true)
        return true
    }

    internal func scheduleInitialBootstrapLocalHistoryFallbackIfNeeded() {
        guard ChatBootstrapLocalHistoryFallbackPolicy.shouldScheduleFallback(
            messageCount: self.messagesObserver?.count ?? 0,
            isShowingSkeleton: self.showSkeletonObserver.value,
            allowsStaleLocalHistory: self.allowsStaleLocalHistoryDuringInitialBootstrap,
            hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest()
        ) else {
            return
        }

        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.initialBootstrapLocalHistoryFallbackWorkItem = nil
            _ = self.revealStaleLocalHistoryIfNeeded()
        }
        self.initialBootstrapLocalHistoryFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ChatBootstrapLocalHistoryFallbackPolicy.fallbackDelay,
            execute: workItem
        )
    }

    internal func cancelInitialBootstrapLocalHistoryFallback() {
        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        self.initialBootstrapLocalHistoryFallbackWorkItem = nil
        self.allowsStaleLocalHistoryDuringInitialBootstrap = false
    }

    @discardableResult
    internal func revealStaleLocalHistoryIfNeeded() -> Bool {
        guard ChatBootstrapLocalHistoryFallbackPolicy.shouldRevealLocalHistory(
            messageCount: self.messagesObserver?.count ?? 0,
            isShowingSkeleton: self.showSkeletonObserver.value,
            hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest()
        ) else {
            return false
        }

        self.initialBootstrapLocalHistoryFallbackWorkItem?.cancel()
        self.initialBootstrapLocalHistoryFallbackWorkItem = nil
        self.allowsStaleLocalHistoryDuringInitialBootstrap = true
        self.applyBootstrapViewState(self.currentBootstrapViewState(), forceRender: true)
        return true
    }

    @discardableResult
    internal func handleInitialBootstrapEndPageIfNeeded(queryId: String, count: Int, persistedMessageCount: Int) -> Bool {
        guard queryId == self.initialBootstrapQueryId else {
            return false
        }

        self.didReceiveInitialBootstrapEndPage = true
        self.initialBootstrapResultCount = count
        self.initialBootstrapPersistedMessageCount = persistedMessageCount
        _ = self.completeInitialBootstrapIfNeeded()
        return true
    }

    internal func capturePagingAnchorIfNeeded(direction: ChatHistoryPageDirection) -> ChatHistoryPageAnchor? {
        let candidateSections = self.messagesCollectionView
            .indexPathsForVisibleItems
            .compactMap(\.section)
            .sorted()
            .filter {
                $0 < self.datasource.count &&
                !self.datasource[$0].isFakeMessage
            }

        let anchorSection: Int?
        switch direction {
        case .older:
            anchorSection = candidateSections.min()
        case .newer:
            anchorSection = self.isNearBottom() ? nil : candidateSections.max()
        }

        guard let section = anchorSection else {
            return nil
        }

        let indexPath = IndexPath(item: 0, section: section)
        let attributes = self.messagesCollectionView.layoutAttributesForItem(at: indexPath)
        let frame = attributes?.frame ?? self.messagesCollectionView.cellForItem(at: indexPath)?.frame

        guard let frame else {
            return nil
        }

        return ChatHistoryPageAnchor(
            primary: self.datasource[section].primary,
            offsetFromViewportTop: frame.minY - self.messagesCollectionView.contentOffset.y
        )
    }

    internal func restorePagingAnchor(_ anchor: ChatHistoryPageAnchor) {
        guard let section = self.datasourceSnapshot.primaryIndex[anchor.primary] else {
            return
        }

        let indexPath = IndexPath(item: 0, section: section)
        self.messagesCollectionView.layoutIfNeeded()

        let attributes = self.messagesCollectionView.layoutAttributesForItem(at: indexPath)
        let frame = attributes?.frame ?? self.messagesCollectionView.cellForItem(at: indexPath)?.frame

        guard let frame else {
            return
        }

        let minOffsetY = -self.messagesCollectionView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            self.messagesCollectionView.contentSize.height -
            self.messagesCollectionView.bounds.height +
            self.messagesCollectionView.adjustedContentInset.bottom
        )
        let targetY = ChatHistoryPageAnchorRestorePolicy.targetContentOffsetY(
            anchorMinY: frame.minY,
            offsetFromViewportTop: anchor.offsetFromViewportTop,
            minContentOffsetY: minOffsetY,
            maxContentOffsetY: maxOffsetY
        )

        self.messagesCollectionView.setContentOffset(
            CGPoint(
                x: self.messagesCollectionView.contentOffset.x,
                y: targetY
            ),
            animated: false
        )
    }

    internal func abortInteractiveHistoryPageLoad() {
        self.interactiveHistoryPageLoadContext = nil
        self.endHistoryLoadingUI(unlockPage: false)
        self.setArchiveLoading(false)
        self.currentPage.unlock()
    }

    internal func finishPagingInteraction(
        window: ChatDatasetWindow,
        shouldApplyWindow: Bool,
        direction: ChatHistoryPageDirection
    ) {
        let applyMode: ChatDatasourceApplyMode = .windowReload(
            keepOffset: ChatHistoryPageApplyPolicy.keepOffset(direction: direction)
        )
        let anchor = self.capturePagingAnchorIfNeeded(direction: direction)

        self.endHistoryLoadingUI(unlockPage: false)

        guard shouldApplyWindow else {
            self.currentPage.unlock()
            return
        }

        self.mapAndApplyWindow(
            window,
            mode: applyMode,
            invalidateLayout: false,
            completion: {
                if let anchor {
                    self.restorePagingAnchor(anchor)
                }
                self.currentPage.unlock()
            },
            cancelledCompletion: {
                self.currentPage.unlock()
            }
        )
    }

    @discardableResult
    internal func completeInteractiveHistoryPageLoadIfNeeded(
        queryId: String,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int
    ) -> Bool {
        guard var context = self.interactiveHistoryPageLoadContext,
              context.queryId == queryId else {
            return false
        }

        context.didReceiveEndPage = true
        context.queryExhausted = state.queryExhausted
        context.persistedMessageCount = state.persistedMessageCount
        context.resultFirst = first
        context.resultLast = last
        self.interactiveHistoryPageLoadContext = context
        _ = self.tryFinishInteractiveHistoryPageLoadIfReady()

        return true
    }

    @discardableResult
    internal func tryFinishInteractiveHistoryPageLoadIfReady() -> Bool {
        guard var context = self.interactiveHistoryPageLoadContext,
              context.didReceiveEndPage else {
            return false
        }

        let currentArchiveState = self.loadChatArchiveStateSnapshot()
        let currentCount = self.messagesObserver?.count ?? 0
        let currentOldestArchivedId = self.observedOldestArchivedId()
        let didAdvance = ChatHistoryPageCompletionPolicy.didAdvance(
            previousObserverCount: context.preLoadObserverCount,
            currentObserverCount: currentCount,
            previousOldestArchivedId: context.preLoadOldestArchivedId,
            currentOldestArchivedId: currentOldestArchivedId,
            previousArchiveEnded: context.preLoadFullArchiveLoaded,
            currentArchiveEnded: currentArchiveState.fullArchiveLoaded
        )
        let isMessagePipelineIdle = !(AccountManager.shared.find(for: self.owner)?.messages.hasPendingMessages(forQueryId: context.queryId) ?? false)
        let requiresObserverSettle = (context.persistedMessageCount ?? 0) > 0

        if requiresObserverSettle && isMessagePipelineIdle && !context.didEnterObserverSettlePhase {
            context.didEnterObserverSettlePhase = true
            self.interactiveHistoryPageLoadContext = context

            DispatchQueue.main.async {
                guard var settleContext = self.interactiveHistoryPageLoadContext,
                      settleContext.queryId == context.queryId else {
                    return
                }
                settleContext.didObservePostIdleTick = true
                self.interactiveHistoryPageLoadContext = settleContext
                _ = self.tryFinishInteractiveHistoryPageLoadIfReady()
            }
            return false
        }

        guard ChatHistoryPageCompletionPolicy.shouldFinish(
            didReceiveEndPage: context.didReceiveEndPage,
            didAdvance: didAdvance,
            persistedMessageCount: context.persistedMessageCount,
            isMessagePipelineIdle: isMessagePipelineIdle,
            requiresObserverSettle: requiresObserverSettle,
            didObservePostIdleTick: context.didObservePostIdleTick
        ) else {
            return false
        }

        let resolvedCursorId = ChatArchiveStateMutationPolicy.resolveCursorId(
            observedCursorId: currentOldestArchivedId,
            transportFirst: context.resultFirst,
            transportLast: context.resultLast,
            currentPersistedCursorId: currentArchiveState.persistedCursorId
        )
        let outcome = ChatHistoryPageOutcomePolicy.resolve(
            queryExhausted: context.queryExhausted,
            didAdvance: didAdvance,
            persistedMessageCount: context.persistedMessageCount ?? 0,
            requestedCursorId: context.requestedCursorId,
            currentCursorId: resolvedCursorId
        )
        let nextFullArchiveLoaded: Bool

        switch outcome {
        case .advanced:
            nextFullArchiveLoaded = false
            self.hasConfirmedArchiveEndThisSession = false
            if context.isArchiveEndVerificationProbe {
                self.hasUsedArchiveEndVerificationProbe = true
            }
        case .duplicateOrNoAdvance:
            nextFullArchiveLoaded = false
            self.hasConfirmedArchiveEndThisSession = false
            if context.isArchiveEndVerificationProbe {
                self.hasUsedArchiveEndVerificationProbe = true
            }
        case .emptyExhausted:
            nextFullArchiveLoaded = true
            self.hasConfirmedArchiveEndThisSession = true
            if context.isArchiveEndVerificationProbe {
                self.hasUsedArchiveEndVerificationProbe = true
            }
        }

        let archiveStatePlan = ChatArchiveStateMutationPolicy.resolvePlan(
            snapshot: currentArchiveState,
            resolvedCursorId: resolvedCursorId,
            nextFullArchiveLoaded: nextFullArchiveLoaded
        )
        _ = self.applyChatArchiveStateIfNeeded(
            snapshot: currentArchiveState,
            plan: archiveStatePlan
        )

        self.interactiveHistoryPageLoadContext = nil
        self.rebuildUnreadMentionItems()

        let previousWindow = self.visibleWindow()
        let observerCountDelta = max(0, currentCount - context.preLoadObserverCount)
        let requestedMaxIndex = context.direction == .older
            ? context.expectedWindowMaxIndex + observerCountDelta
            : context.expectedWindowMaxIndex
        let requestedWindow = self.datasetCoordinator.clamp(
            ChatDatasetWindow(
                minIndex: context.requestedWindow.minIndex,
                maxIndex: requestedMaxIndex
            ),
            totalCount: currentCount
        )
        let shouldApplyWindow = previousWindow != requestedWindow || didAdvance

        self.syncCurrentPage(with: requestedWindow)
        self.finishPagingInteraction(
            window: requestedWindow,
            shouldApplyWindow: shouldApplyWindow,
            direction: context.direction
        )

        return true
    }

    internal func mapAndApplyWindow(
        _ window: ChatDatasetWindow,
        mode: ChatDatasourceApplyMode,
        animated: Bool = true,
        invalidateLayout: Bool = false,
        completion: (() -> Void)? = nil,
        cancelledCompletion: (() -> Void)? = nil
    ) {
        let normalizedWindow = self.datasetCoordinator.clamp(window, totalCount: self.messagesObserver?.count ?? 0)
        let slice = self.sliceForWindow(normalizedWindow)

        self.datasetMappingGeneration += 1
        let generation = self.datasetMappingGeneration

        self.datasetMappingQueue.async {
            let mappedDatasource = self.mapDataset(dataset: slice)

            DispatchQueue.main.async {
                guard ChatDatasourceApplyGenerationPolicy.shouldApply(
                    requestGeneration: generation,
                    currentGeneration: self.datasetMappingGeneration
                ) else {
                    cancelledCompletion?()
                    return
                }
                self.syncCurrentPage(with: normalizedWindow)
                self.applyChatDatasource(mappedDatasource, mode: mode, animated: animated, invalidateLayout: invalidateLayout, completion: completion)
            }
        }
    }

    internal var isShowingBootstrapPlaceholder: Bool {
        self.datasource.isEmpty || self.datasource.allSatisfy(\.isFakeMessage)
    }

    internal var shouldAnimateInitialHistoryAppearance: Bool {
        ChatInitialHistoryAppearancePolicy.shouldAnimateDatasourceApply(isInitialHistoryAppearancePending: self.initialHistoryAppearancePending)
    }

    internal func finishInitialHistoryAppearanceIfPossible() {
        guard self.initialHistoryAppearancePending,
              ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance,
                hasRenderedStableHistory: self.hasRenderedStableInitialHistory
              ) else { return }

        DispatchQueue.main.async {
            guard self.initialHistoryAppearancePending,
                  ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                    hasViewAppeared: self.hasCompletedInitialHistoryViewAppearance,
                    hasRenderedStableHistory: self.hasRenderedStableInitialHistory
                  ) else { return }

            self.initialHistoryAppearancePending = false
            self.hasRenderedStableInitialHistory = false
        }
    }

    internal func bootstrapViewState(chatInstance: LastChatsStorageItem?) -> ChatBootstrapViewState {
        ChatBootstrapViewState.resolve(
            messageCount: self.messagesObserver?.count ?? 0,
            isSynced: chatInstance?.isSynced ?? false,
            isInitialBootstrapInFlight: self.isInitialBootstrapInFlight,
            hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest(),
            allowsStaleLocalHistory: self.allowsStaleLocalHistoryDuringInitialBootstrap
        )
    }

    internal func currentBootstrapViewState() -> ChatBootstrapViewState {
        do {
            let realm = try WRealm.safe()
            let chatInstance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: self.jid,
                    owner: self.owner,
                    conversationType: self.conversationType
                )
            )
            return self.bootstrapViewState(chatInstance: chatInstance)
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
            return ChatBootstrapViewState.resolve(
                messageCount: self.messagesObserver?.count ?? 0,
                isSynced: false,
                isInitialBootstrapInFlight: self.isInitialBootstrapInFlight,
                hasPendingInitialAnchorRequest: self.hasPendingInitialAnchorRequest(),
                allowsStaleLocalHistory: self.allowsStaleLocalHistoryDuringInitialBootstrap
            )
        }
    }

    internal func hasPendingInitialAnchorRequest() -> Bool {
        if let executionState = self.activeAnchorExecutionState,
           executionState.request.owner == self.owner,
           executionState.request.chatJid == self.jid,
           executionState.request.conversationType == self.conversationType,
           executionState.usesBootstrapLoading,
           !executionState.isPositioning {
            return true
        }

        guard self.isShowingBootstrapPlaceholder,
              let request = self.pendingOpenMessageRequest,
              request.owner == self.owner,
              request.chatJid == self.jid,
              request.conversationType == self.conversationType else {
            return false
        }

        return true
    }

    @discardableResult
    internal func reloadInitialWindowAfterBootstrapIfNeeded(force: Bool = false) -> Bool {
        let state = self.currentBootstrapViewState()
        guard force || self.isShowingBootstrapPlaceholder else { return false }

        switch state {
        case .skeleton:
            self.unreadMentionItems = []
            self.unreadMentionsState = .empty
            self.syncCurrentPage(with: .empty)
            self.applyChatDatasource(self.mapDataset(dataset: []), mode: .fullReload(), animated: self.shouldAnimateInitialHistoryAppearance)
            self.setShouldShowInitialMessage(false)
        case .content:
            self.rebuildUnreadMentionItems()
            let window = self.datasetCoordinator.initialWindow(totalCount: self.messagesObserver?.count ?? 0)
            self.syncCurrentPage(with: window)
            self.setShouldShowInitialMessage(false)
            self.mapAndApplyWindow(window, mode: .fullReload(), animated: self.shouldAnimateInitialHistoryAppearance)
        case .empty:
            self.unreadMentionItems = []
            self.unreadMentionsState = .empty
            self.syncCurrentPage(with: .empty)
            self.applyChatDatasource([], mode: .fullReload(), animated: self.shouldAnimateInitialHistoryAppearance)
            self.setShouldShowInitialMessage(true)
        }
        return true
    }

    internal func applyBootstrapViewState(_ state: ChatBootstrapViewState, forceRender: Bool = false) {
        switch state {
        case .skeleton:
            self.setDatasourceLoadingEnabled(false)
            self.setShouldShowInitialMessage(false)
            self.setSkeletonVisible(true)
            if ChatBootstrapSkeletonRenderPolicy.shouldRenderSkeletonDatasource(
                forceRender: forceRender,
                isDatasourceEmpty: self.datasource.isEmpty,
                isShowingBootstrapPlaceholder: self.isShowingBootstrapPlaceholder
            ) {
                self.applyChatDatasource(self.mapDataset(dataset: []), mode: .fullReload(), animated: self.shouldAnimateInitialHistoryAppearance)
            }
        case .content, .empty:
            self.setDatasourceLoadingEnabled(true)
            self.setSkeletonVisible(false)
            self.reloadInitialWindowAfterBootstrapIfNeeded(force: forceRender)
        }
    }
    
    internal final func mapDataset(dataset: Array<MessageStorageItem>) -> [Datasource] {
        if self.showSkeletonObserver.value {
            return skeletonMessages.enumerated().compactMap {
                (offset, item) in
                let date = Date(timeIntervalSince1970: Date().timeIntervalSince1970 - Double(((self.skeletonMessages.count - offset) * 1000)))
                return Datasource(
                    primary: UUID().uuidString,
                    jid: self.jid,
                    owner: self.owner,
                    outgoing: ((offset % 3) == 0),
                    sender: self.opponentSender,
                    messageId: UUID().uuidString,
                    sentDate: date,
                    editDate: nil,
                    kind: .skeleton(item),
                    withAuthor: false,
                    withAvatar: false,
                    error: false,
                    errorType: "",
                    canPinMessage: false,
                    canEditMessage: false,
                    canDeleteMessage: false,
                    forwards: [],
                    isOutgoing: ((offset % 3) == 0),
                    isEdited: false,
                    groupchatAuthorRole: "",
                    groupchatAuthorId: "",
                    groupchatAuthorNickname: "",
                    groupchatAuthorBadge: "",
                    isHasAttachedMessages: false,
                    isDownloaded: true,
                    state: .read,
                    searchString: nil,
                    errorMetadata: [:],
                    burnDate: -1,
                    afterburnInterval: -1,
                    isRead: true,
                    isFakeMessage: true,
                    images: [],
                    videos: [],
                    files: [],
                    audios: [],
                    timeMarkerText: NSAttributedString(),
                    indicator: .none
                )
            }
        }
        var out: [Datasource] = []
        var unreadId: String? = nil
        do {
            let realm = try WRealm.safe()
            let lastChatInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid, owner: self.owner, conversationType: self.conversationType))
            unreadId = lastChatInstance?.lastReadId
            unreadId = (lastChatInstance?.unread ?? 0) == 0 ? nil : unreadId
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }

        func appendDateSeparatorIfNeeded(before item: MessageStorageItem, at offset: Int) {
            guard offset == 0 || self.isDateChange(from: dataset[offset - 1].sentDate, to: item.sentDate) else {
                return
            }
            let kind: MessageKind = .date(
                NSAttributedString(
                    string: sectionsDateFormatter.string(from: item.sentDate),
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .caption1),
                        .foregroundColor: UIColor.white,
                    ]
                )
            )
            out.append(Datasource(
                primary: "\(item.primary) date changed",
                jid: self.jid,
                owner: self.owner,
                outgoing: item.outgoing,
                sender: item.outgoing ? self.ownerSender : self.opponentSender,
                messageId: item.messageId,
                sentDate: item.date,
                editDate: nil,
                kind: kind,
                withAuthor: false,
                withAvatar: false,
                error: item.state == .error,
                errorType: "",
                canPinMessage: false,
                canEditMessage: false,
                canDeleteMessage: false,
                forwards: [],
                isOutgoing: item.outgoing,
                isEdited: false,
                groupchatAuthorRole: "",
                groupchatAuthorId: "",
                groupchatAuthorNickname: "",
                groupchatAuthorBadge: "",
                isHasAttachedMessages: false,
                isDownloaded: true,
                state: .none,
                searchString:  "",
                errorMetadata: nil,
                burnDate: 0,
                afterburnInterval: 0,
                archivedId: "\(item.archivedId) date changed",
                queryIds: "\(item.queryIds ?? "") date changed",
                isRead: item.isRead,
                selectedSearchResultId: nil,
                isHadHistoryGap: false,
                isFakeMessage: true,
                images: [],
                videos: [],
                files: [],
                audios: [],
                timeMarkerText: NSAttributedString(),
                indicator: .none,
                avatarUrl: nil
            ))
        }
                
        dataset.enumerated().forEach {
            (offset, item) in
            appendDateSeparatorIfNeeded(before: item, at: offset)
//            let references = Array(item.references.toArray().compactMap { $0.loadModel() })
//            let inlineForwards = Array(item.inlineForwards.sorted(byKeyPath: "originalDate", ascending: true).toArray().compactMap { $0.loadModel() })
            
            let isDownloaded = !item.references.filter { $0.isDownloaded }.isEmpty
            let kind: MessageKind
            switch item.displayAs {
                case .text:
                    kind = .attributedText(
                        item.createRefBody(
                            [
                                NSAttributedString.Key.foregroundColor: UIColor.label,
                                NSAttributedString.Key.font: UIFont.preferredFont(forTextStyle: .body)//UIFont.systemFont(ofSize: 16, weight: .regular),
                            ],
                            searchedText: self.searchTextObserver.value,
                            searchedTextColor: .systemGreen
                        )
                    )
                case .call:
                    kind = .call(CallAttachment(primary: item.primary, incoming: !item.outgoing, missed: item.references.first?.metadata?["callState"] as? String == "missed"))
//                    kind = .attributedText(NSAttributedString())
                case .system:
                    kind = .system(
                        NSAttributedString(
                            string: item.body,
                            attributes: [
                                .font: UIFont.preferredFont(forTextStyle: .caption1).italic(),
                                .foregroundColor: UIColor.white,
                            ]
                        )
                    )
                case .sticker:
//                    if let reference = references.filter({ $0.kind == .media }).first {
//                        kind = .sticker(reference)
//                    } else {
                        kind = .attributedText(NSAttributedString())
//                    }
            }
            
            var withAuthor: Bool = false
            var withAvatar: Bool = false
            var tailed: Bool = true
            let date = item.date
            let prevMessage = offset - 1
            let nextMessage = offset + 1
            
            if self.avatarVerticalPosition == "top" {
                if prevMessage >= 0 {
                    let prevItem = dataset[prevMessage]
                    if self.conversationType == .group {
                        withAvatar = !(prevItem.groupchatCard?.userId == item.groupchatCard?.userId)
                        tailed = !(prevItem.groupchatCard?.userId == item.groupchatCard?.userId)
                        
                    } else {
                        tailed = !(item.outgoing == prevItem.outgoing)
                    }
                    if isDateChange(from: item.date, to: prevItem.date) {
                        tailed = true
                        if self.conversationType == .group {
                            withAvatar = true
                        }
                    }
                }
            }
            if prevMessage >= 0 {
                let prevItem = dataset[prevMessage]
                if self.conversationType == .group {
                    withAuthor = !(prevItem.groupchatCard?.userId == item.groupchatCard?.userId)
                    if isDateChange(from: item.date, to: prevItem.date) {
                        withAuthor = true
                    }
                }
            } else if self.conversationType == .group {
                withAuthor = true
            }

            if nextMessage < dataset.count {
                let nextItem = dataset[nextMessage]
                
                if self.avatarVerticalPosition == "bottom" {
                    if self.conversationType == .group {
                        withAvatar = !(nextItem.groupchatCard?.userId == item.groupchatCard?.userId)
                        tailed = !(nextItem.groupchatCard?.userId == item.groupchatCard?.userId)
                        
                    } else {
                        tailed = !(item.outgoing == nextItem.outgoing)
                    }
                    if isDateChange(from: item.date, to: nextItem.date) {
                        tailed = true
                        if self.conversationType == .group {
                            withAvatar = true
                        }
                    }
                }
            }
            var attributedAuthor: NSAttributedString? = nil
            if withAuthor && !item.outgoing {
                if let nickname = item.groupchatAuthorNickname,
                   nickname.isNotEmpty,
                   let uuid = item.groupchatCard?.jid
                        ?? item.groupchatCard?.userId
                        ?? item.groupchatMetadata?["jid"] as? String
                        ?? item.groupchatAuthorId,
                   uuid.isNotEmpty {
                    attributedAuthor = NSAttributedString(string: nickname, attributes: [
                        .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                        .foregroundColor: ChatViewController.getUsernamePalette(for: uuid).tint500
                    ])
                }
            }
          
            if item.editDate != nil {
                let primary = item.primary
                DispatchQueue.main.async {
                    (self.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout)?.invalidateLastMessageCachedSize(primary: primary)
                }
            }
            var searchString: String? = nil
            
            if self.inSearchMode.value,
               item.displayAs == .text,
               let str = self.searchTextObserver.value,
               str.isNotEmpty,
               item.body.contains(str) {
                searchString = str
            }
            
            
            let references = item.references.toArray()
            let mappedReferences = Self.mapReferenceAttachments(references, revealedSensitiveMediaPrimaries: self.revealedSensitiveMediaPrimaries)
            let forwards: [MessageAttachment] = item.inlineForwards.toArray().compactMap({ return mapAttachment($0) })
            var indicator: IndicatorType = .none
            if item.outgoing {
                switch item.state {
                        
                    case .sended:
                        indicator = .sended
                    case .deliver:
                        indicator = .received
                    case .read:
                        indicator = .read
                    case .error:
                        indicator = .error
                    case .none:
                        indicator = .none
                    case .notSended:
                        indicator = .error
                    case .sending:
                        indicator = .sending
                    case .uploading:
                        indicator = .sending
                }
            }
            
            var timeString = Self.attachmentTimeFormatter.string(from: item.date)
            if item.afterburnInterval > 0 {
                timeString = "\(timeString) ⦁ \(item.afterburnInterval.prettyMinuteFormatedString)"
            }
            if item.editDate != nil {
                timeString = "\(timeString) (edited)"
            }
            let timeMarkerString = NSAttributedString(
                string: timeString,
                attributes: [
                    NSAttributedString.Key.foregroundColor: UIColor(red: 158.0 / 255.0, green: 158.0 / 255.0, blue: 158.0 / 255.0, alpha: 1),
                    NSAttributedString.Key.font: UIFont.systemFont(ofSize: 10, weight: .regular)
                ]
            )
            if item.outgoing {
                withAuthor = false
            }
//            if (dataset.count > 1 && (offset + 1) < dataset.count) || (offset + 1 == dataset.count) {
//                if item.archivedId == unreadId {
//                    let kind: MessageKind = .unread(
//                        NSAttributedString(
//                            string: "Unread messages",
//                            attributes: [
//                                .font: UIFont.preferredFont(forTextStyle: .caption1),
//                                .foregroundColor: UIColor.white,
//                            ]
//                        )
//                    )
//                    self.unreadMessagePositionId = offset
//                    out.append(Datasource(
//                        primary: "\(item.primary) unread",
//                        jid: self.jid,
//                        owner: self.owner,
//                        outgoing: item.outgoing,
//                        sender: item.outgoing ? self.ownerSender : self.opponentSender,
//                        messageId: item.messageId,
//                        sentDate: date,
//                        editDate: nil,
//                        kind: kind,
//                        withAuthor: false,
//                        withAvatar: false,//self.groupchat ? !item.outgoing : false,
//                        error: item.state == .error,
//                        errorType: "",
//                        canPinMessage: false,
//                        canEditMessage: false,
//                        canDeleteMessage: false,
//                        forwards: [],
//                        isOutgoing: item.outgoing,
//                        isEdited: false,
//                        groupchatAuthorRole: "",
//                        groupchatAuthorId: "",
//                        groupchatAuthorNickname: "",
//                        groupchatAuthorBadge: "",
//                        isHasAttachedMessages: false,
//                        isDownloaded: true,
//                        state: .none,
//                        searchString:  "",
//                        errorMetadata: nil,
//                        burnDate: 0,
//                        afterburnInterval: 0,
//                        archivedId: "\(item.archivedId) unread",
//                        queryIds: "\(item.queryIds ?? "") unread",
//                        isRead: item.isRead,
//                        selectedSearchResultId: nil,//item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil,
//                        isHadHistoryGap: false,
//                        isFakeMessage: true,
//                        images: [],
//                        videos: [],
//                        files: [],
//                        audios: [],
//                        timeMarkerText: NSAttributedString(),
//                        indicator: .none,
//                        avatarUrl: nil
//                    ))
//                }
//            }
            out.append(Datasource(
                primary: item.primary,
                jid: self.jid,
                owner: self.owner,
                outgoing: item.outgoing,
                sender: item.outgoing ? self.ownerSender : self.opponentSender,
                messageId: item.messageId,
                sentDate: date,
                editDate: item.editDate,
                kind: kind,
                withAuthor: withAuthor,
                withAvatar: self.conversationType == .group && !item.outgoing,
                error: item.state == .error,
                errorType: item.messageError ?? "",
                canPinMessage: [.system, .sticker].contains(item.displayAs) ? false : self.canUnpinMessage.value,
                canEditMessage: item.archivedId.isNotEmpty ? item.displayAs == .text && item.outgoing : false,
                canDeleteMessage: [MessageStorageItem.MessageSendingState.deliver, MessageStorageItem.MessageSendingState.read].contains(item.state),
                forwards: forwards,
                isOutgoing: item.outgoing,
                isEdited: item.editDate != nil,
                groupchatAuthorRole: item.groupchatMetadata?["role"] as? String ?? "member",
                groupchatAuthorId: item.groupchatAuthorId ?? "",
                groupchatAuthorNickname: item.groupchatAuthorNickname ?? "",
                groupchatAuthorBadge: item.groupchatAuthorBadge ?? "",
                isHasAttachedMessages: item.isHasAttachedMessages,
                isDownloaded: isDownloaded,
                state: item.displayAs == .call ? .none : item.state,
                searchString:  searchString,
                errorMetadata: item.errorMetadata,
                messageWarningText: item.messageWarningText,
                burnDate: item.burnDate,
                afterburnInterval: item.afterburnInterval,
                archivedId: item.archivedId,
                queryIds: item.queryIds,
                isRead: item.isRead,
                selectedSearchResultId: nil,//item.archivedId == self.selectedSearchResultId ? self.selectedSearchResultId : nil,
                isHadHistoryGap: false,
                tailed: tailed,
                    images: mappedReferences.images,
                    videos: mappedReferences.videos,
                    files: mappedReferences.files,
                    audios: mappedReferences.audio,
                timeMarkerText: timeMarkerString,
                indicator: indicator,
                avatarUrl: withAvatar ? item.groupchatCard?.avatarURI : nil,
                attributedAuthor: attributedAuthor
            ))
        }
        return out
    }
    
    private final func convertChangeset(changes: [Change<Datasource>]) -> ChangesWithIndexSet {
        let inserts = IndexSet(changes.compactMap({ return $0.insert?.index }))
        let deletes = IndexSet(changes.compactMap({ return $0.delete?.index }))
        let replaces = IndexSet(changes.compactMap({ return $0.replace?.index }))
        let moves = changes.compactMap({ $0.move }).map({
          (
            from: IndexPath(item: 0, section: $0.fromIndex),
            to: IndexPath(item: 0, section: $0.toIndex)
          )
        })
        
        return ChangesWithIndexSet(
            inserts: inserts,
            deletes: deletes,
            replaces: replaces,
            moves: moves
        )
    }
    
    internal final func onTouchStartPage(direction: ChatHistoryPageDirection) {
        print(#function)
        guard self.currentPage.isUnlocked else {
            return
        }
        FeedbackManager.shared.generate(feedback: .success)
        self.beginHistoryLoadingUI()
        self.currentPage.prevPage {
            self.loadDatasource(direction: direction) { addditional in
                let window = self.visibleWindow()
                self.finishPagingInteraction(
                    window: window,
                    shouldApplyWindow: addditional.isNotEmpty,
                    direction: direction
                )
            }
        }
    }
    
    internal final func onTouchEndPage(direction: ChatHistoryPageDirection) {
        print(#function)
        guard self.currentPage.isUnlocked else {
            return
        }
        FeedbackManager.shared.generate(feedback: .success)
        self.beginHistoryLoadingUI()
        self.currentPage.nextPage(autoUnlock: false) {
            self.loadDatasource(direction: direction) { addditional in
                let window = self.visibleWindow()
                self.finishPagingInteraction(
                    window: window,
                    shouldApplyWindow: addditional.isNotEmpty,
                    direction: direction
                )
            }
        }
    }
    
    internal final func loadInitialDatasource() {
        do {
            let realm = try WRealm.safe()
            let chatInstance = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: self.jid,
                                                               owner: self.owner,
                                                               conversationType: self.conversationType))
            self.rebuildUnreadMentionItems()
            self.applyBootstrapViewState(self.bootstrapViewState(chatInstance: chatInstance), forceRender: true)
            self.performPendingOpenMessageRequestIfNeeded()
        } catch {
            DDLogDebug("ChatViewController: \(#function). \(error.localizedDescription)")
        }
    }
    
    internal final func loadDatasource(direction: ChatHistoryPageDirection, first: Bool = false, ignoreGaps: Bool = false, samePage: Bool = false, callback: @escaping ((Array<MessageStorageItem>) -> Void)) {
        func getWindow() -> ChatDatasetWindow {
            let currentWindow = self.visibleWindow()

            if samePage {
                return self.datasetCoordinator.clamp(currentWindow, totalCount: self.messagesObserver.count)
            }

            return self.datasetCoordinator.nextWindow(
                from: currentWindow,
                direction: direction
            )
        }
        
        guard self.messagesObserver != nil else {
            self.setDatasourceLoadingEnabled(true)
            self.currentPage.unlock()
            callback([])
            return
        }
        let currentWindow = self.visibleWindow()
        let requestedWindow = getWindow()
        if requestedWindow.isEmpty && !first {
            self.setDatasourceLoadingEnabled(true)
            self.currentPage.unlock()
            callback([])
            return
        }
        let localWindow = self.datasetCoordinator.clamp(requestedWindow, totalCount: self.messagesObserver.count)
        let chatArchiveState = self.loadChatArchiveStateSnapshot()
        let persistedArchiveEnded = chatArchiveState.fullArchiveLoaded
        let shouldProbePersistedArchiveEnd = ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
            persistedArchiveEnded: persistedArchiveEnded,
            hasConfirmedArchiveEndThisSession: self.hasConfirmedArchiveEndThisSession,
            hasUsedVerificationProbe: self.hasUsedArchiveEndVerificationProbe
        )
        let effectiveArchiveEnded = ChatArchiveEndVerificationPolicy.effectiveArchiveEnded(
            persistedArchiveEnded: persistedArchiveEnded,
            shouldProbePersistedArchiveEnd: shouldProbePersistedArchiveEnd
        )
        let decision = ChatHistoryPagingPolicy.loadDecision(
            direction: direction,
            currentWindow: currentWindow,
            requestedWindow: requestedWindow,
            localWindow: localWindow,
            totalCount: self.messagesObserver.count,
            isArchiveEnded: effectiveArchiveEnded,
            hasKnownNewerGap: chatArchiveState.hasKnownNewerGap,
            newerLiveEdgeReached: chatArchiveState.newerLiveEdgeReached
        )

        switch decision {
        case .localOnly:
            let window = self.datasetCoordinator.clamp(localWindow, totalCount: self.messagesObserver.count)
            self.syncCurrentPage(with: window)
            callback(self.sliceForWindow(window))
        case .remoteOlderPage:
            let archivedId = self.authoritativeOlderPagingCursorId(persistedCursorId: chatArchiveState.persistedCursorId)
            let queryId = "MAM next history: \(NanoID.new(6))"
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: nil,
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            self.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
                queryId: queryId,
                direction: direction,
                chatPrimaryKey: chatArchiveState.primaryKey,
                persistedCursorId: chatArchiveState.persistedCursorId,
                persistedFullArchiveLoaded: chatArchiveState.fullArchiveLoaded,
                requestedCursorId: archivedId,
                requestedWindow: requestedWindow,
                preLoadObserverCount: self.messagesObserver.count,
                preLoadOldestArchivedId: self.observedOldestArchivedId(),
                preLoadFullArchiveLoaded: shouldProbePersistedArchiveEnd ? false : persistedArchiveEnded,
                remoteFetchStarted: true,
                isArchiveEndVerificationProbe: shouldProbePersistedArchiveEnd,
                expectedWindowMaxIndex: requestedWindow.maxIndex
            )
            self.currentPage.locked = true
            self.setArchiveLoading(true)

            let requestRemoteHistory: (XMPPStream, MessageArchiveManager) -> String = { stream, mam in
                mam.getNextHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    messageId: archivedId,
                    pageSize: self.datasourcePageSize,
                    queryId: queryId,
                    callback: nil,
                    requestCallbacks: requestCallbacks
                )
            }

            let requestFallbackHistory = {
                guard let account = AccountManager.shared.find(for: self.owner) else {
                    DispatchQueue.main.async {
                        self.abortInteractiveHistoryPageLoad()
                    }
                    return
                }

                account.action { user, stream in
                    _ = requestRemoteHistory(stream, user.mam)
                }
            }

            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                if let mam = session.mam {
                    _ = requestRemoteHistory(stream, mam)
                } else {
                    requestFallbackHistory()
                }
            } fail: {
                requestFallbackHistory()
            }
        case .remoteNewerPage:
            guard let archivedId = self.authoritativeNewerPagingCursorId(persistedCursorId: chatArchiveState.newestCursorId),
                  archivedId.isNotEmpty else {
                self.setDatasourceLoadingEnabled(true)
                self.currentPage.unlock()
                callback([])
                return
            }
            let queryId = "MAM prev history: \(NanoID.new(6))"
            let requestCallbacks = MessageArchiveManager.RequestCallbacks(
                onMessage: nil,
                onEndPage: { [weak self] queryId, state, first, last, count in
                    self?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
                }
            )
            self.interactiveHistoryPageLoadContext = ChatInteractiveHistoryPageLoadContext(
                queryId: queryId,
                direction: direction,
                chatPrimaryKey: chatArchiveState.primaryKey,
                persistedCursorId: chatArchiveState.newestCursorId,
                persistedFullArchiveLoaded: chatArchiveState.fullArchiveLoaded,
                requestedCursorId: archivedId,
                requestedWindow: requestedWindow,
                preLoadObserverCount: self.messagesObserver.count,
                preLoadOldestArchivedId: self.observedOldestArchivedId(),
                preLoadFullArchiveLoaded: effectiveArchiveEnded,
                remoteFetchStarted: true,
                isArchiveEndVerificationProbe: false,
                expectedWindowMaxIndex: requestedWindow.maxIndex
            )
            self.currentPage.locked = true
            self.setArchiveLoading(true)

            let requestRemoteHistory: (XMPPStream, MessageArchiveManager) -> String = { stream, mam in
                mam.getPrevHistory(
                    stream,
                    for: self.jid,
                    conversationType: self.conversationType,
                    messageId: archivedId,
                    pageSize: self.datasourcePageSize,
                    queryId: queryId,
                    callback: nil,
                    requestCallbacks: requestCallbacks
                )
            }

            let requestFallbackHistory = {
                guard let account = AccountManager.shared.find(for: self.owner) else {
                    DispatchQueue.main.async {
                        self.abortInteractiveHistoryPageLoad()
                    }
                    return
                }

                account.action { user, stream in
                    _ = requestRemoteHistory(stream, user.mam)
                }
            }

            XMPPUIActionManager.shared.performRequest(owner: self.owner) { stream, session in
                if let mam = session.mam {
                    _ = requestRemoteHistory(stream, mam)
                } else {
                    requestFallbackHistory()
                }
            } fail: {
                requestFallbackHistory()
            }
        case .endReached:
            self.setDatasourceLoadingEnabled(true)
            self.currentPage.unlock()
            callback([])
            return
        }
    }
    
    
    func didReceiveChangeset() {
        if self.datasource.isNotEmpty {
            self.setShouldShowInitialMessage(false)
        }
        self.ensureObserverLookupMaps()
        self.rebuildUnreadMentionItems()
        guard let maxPrimary = self.datasource.filter({ !$0.isFakeMessage }).last?.primary,
              let maxIndexRaw = self.observerPrimaryIndexMap[maxPrimary] else {
            return
        }
        let loadedWindowCount = max(self.visibleWindow().count, self.datasourcePageSize)
        var maxIndex = maxIndexRaw + 1
        if self.currentPage.maxIndex >= max(0, self.messagesObserver.count - 1) {
            maxIndex = self.messagesObserver.count
        }
        let minIndex = max(0, maxIndex - loadedWindowCount)
        let window = self.datasetCoordinator.clamp(ChatDatasetWindow(minIndex: minIndex, maxIndex: maxIndex), totalCount: self.messagesObserver.count)
        self.mapAndApplyWindow(window, mode: .targetedDiff, animated: self.shouldAnimateInitialHistoryAppearance, invalidateLayout: false)
        self.performPendingOpenMessageRequestIfNeeded(trigger: .observerRefresh)
    }
    
    internal func scrollToLastOrUnreadItem() {
        if ChatInitialScrollPolicy.shouldDeferDefaultScroll(
            hasPendingAnchorRequest: self.pendingOpenMessageRequest != nil,
            isAnchorNavigationInFlight: self.isMessageAnchorNavigationInFlight
        ) {
            self.performPendingOpenMessageRequestIfNeeded()
            return
        }
        let shouldAnimateScroll = !self.initialHistoryAppearancePending
        let latestWindow = self.datasetCoordinator.initialWindow(totalCount: self.messagesObserver.count)
        if self.visibleWindow() != latestWindow {
            self.currentPage.setCustomPage(0) {
                self.syncCurrentPage(with: latestWindow)
                self.currentPage.unlock()
                self.mapAndApplyWindow(latestWindow, mode: .windowReload(), animated: shouldAnimateScroll, invalidateLayout: true, completion: {
                    if let index = self.unreadMessagePositionId {
                        if Set(self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ return $0.section })).contains(index) {
                            self.scrollToBottom(animated: false)
                        } else {
                            self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: .centeredVertically, animated: false)
                        }
                    } else {
                        self.scrollToBottom(animated: false)
                    }
                    self.setFloatingDateVisible(true)
                })
            }
            return
        }
        if let index = self.unreadMessagePositionId {
            if Set(self.messagesCollectionView.indexPathsForVisibleItems.compactMap({ return $0.section })).contains(index) {
                self.scrollToBottom(animated: shouldAnimateScroll)
            } else {
                self.messagesCollectionView.scrollToItem(at: IndexPath(row: 0, section: index), at: .centeredVertically, animated: shouldAnimateScroll)
            }
        } else {
            if self.datasource.isNotEmpty {
                self.scrollToBottom(animated: shouldAnimateScroll)
            }
        }
    }
}
