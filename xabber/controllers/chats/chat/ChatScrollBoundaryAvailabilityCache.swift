import Foundation

protocol ChatScrollBoundaryLocalHistoryAvailabilityProviding {
    func hasOlderLocalPage(before boundary: ChatTimelineBoundary) -> Bool
    func hasNewerLocalPage(after boundary: ChatTimelineBoundary) -> Bool
}

struct ChatScrollBoundaryAvailability: Equatable {
    static let empty = ChatScrollBoundaryAvailability(
        hasLocalOlderPage: false,
        hasLocalNewerPage: false,
        hasKnownArchiveGapAbove: false,
        hasKnownArchiveGapBelow: false,
        hasRemoteOlderPage: false,
        hasRemoteNewerPage: false,
        isRemotePageInFlight: false
    )

    let hasLocalOlderPage: Bool
    let hasLocalNewerPage: Bool
    let hasKnownArchiveGapAbove: Bool
    let hasKnownArchiveGapBelow: Bool
    let hasRemoteOlderPage: Bool
    let hasRemoteNewerPage: Bool
    let isRemotePageInFlight: Bool
}

struct ChatScrollBoundaryAvailabilityCache: Equatable {
    static let empty = ChatScrollBoundaryAvailabilityCache()

    private var conversationKey: ChatTimelineConversationKey?
    private var cachedAvailability: ChatScrollBoundaryAvailability?

    mutating func invalidate() {
        conversationKey = nil
        cachedAvailability = nil
    }

    mutating func refresh(
        conversationKey: ChatTimelineConversationKey,
        timelineState: ChatVirtualTimelineState,
        archiveState: ChatArchiveStateSnapshot,
        provider: ChatScrollBoundaryLocalHistoryAvailabilityProviding,
        hasConfirmedArchiveEndThisSession: Bool,
        hasUsedArchiveEndVerificationProbe: Bool
    ) {
        let normalizedState = timelineState.normalized(
            owner: conversationKey.owner,
            jid: conversationKey.jid,
            conversationType: conversationKey.conversationType
        )
        let isRemotePageInFlight = normalizedState.activeRemoteLoad != nil
        let hasLocalOlderPage = !isRemotePageInFlight && (normalizedState.oldest.map {
            provider.hasOlderLocalPage(before: $0)
        } == true)
        let hasLocalNewerPage = !isRemotePageInFlight && (normalizedState.newest.map {
            provider.hasNewerLocalPage(after: $0)
        } == true)
        let hasKnownArchiveGapAbove = Self.hasKnownArchiveGapAbove(
            timelineState: normalizedState,
            knownGaps: archiveState.knownGaps
        )
        let hasKnownArchiveGapBelow = Self.hasKnownArchiveGapBelow(
            timelineState: normalizedState,
            knownGaps: archiveState.knownGaps
        )
        let shouldProbePersistedArchiveEnd = ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
            persistedArchiveEnded: archiveState.fullArchiveLoaded,
            hasConfirmedArchiveEndThisSession: hasConfirmedArchiveEndThisSession,
            hasUsedVerificationProbe: hasUsedArchiveEndVerificationProbe
        )
        let effectiveArchiveEnded = ChatArchiveEndVerificationPolicy.effectiveArchiveEnded(
            persistedArchiveEnded: archiveState.fullArchiveLoaded,
            shouldProbePersistedArchiveEnd: shouldProbePersistedArchiveEnd
        )

        self.conversationKey = conversationKey
        self.cachedAvailability = ChatScrollBoundaryAvailability(
            hasLocalOlderPage: hasLocalOlderPage,
            hasLocalNewerPage: hasLocalNewerPage,
            hasKnownArchiveGapAbove: hasKnownArchiveGapAbove,
            hasKnownArchiveGapBelow: hasKnownArchiveGapBelow,
            hasRemoteOlderPage: !isRemotePageInFlight && (!effectiveArchiveEnded || hasKnownArchiveGapAbove),
            hasRemoteNewerPage: !isRemotePageInFlight && (hasKnownArchiveGapBelow || !archiveState.newerLiveEdgeReached),
            isRemotePageInFlight: isRemotePageInFlight
        )
    }

    func availability(for conversationKey: ChatTimelineConversationKey) -> ChatScrollBoundaryAvailability? {
        guard self.conversationKey == conversationKey else {
            return nil
        }
        return cachedAvailability
    }

    private static func hasKnownArchiveGapAbove(
        timelineState: ChatVirtualTimelineState,
        knownGaps: [RegularChatArchiveGap]
    ) -> Bool {
        guard knownGaps.isNotEmpty,
              let oldest = timelineState.oldest?.archivedId,
              let newest = timelineState.newest?.archivedId else {
            return false
        }

        return knownGaps.contains {
            containsNewerSide(of: $0, oldest: oldest, newest: newest)
        }
    }

    private static func hasKnownArchiveGapBelow(
        timelineState: ChatVirtualTimelineState,
        knownGaps: [RegularChatArchiveGap]
    ) -> Bool {
        guard knownGaps.isNotEmpty,
              let oldest = timelineState.oldest?.archivedId,
              let newest = timelineState.newest?.archivedId else {
            return false
        }

        return knownGaps.contains {
            containsOlderSide(of: $0, oldest: oldest, newest: newest)
        }
    }

    private static func containsOlderSide(
        of gap: RegularChatArchiveGap,
        oldest: String,
        newest: String
    ) -> Bool {
        let oldestIsOlderSide = (compareArchiveIds(oldest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending
        let newestIsOlderSide = (compareArchiveIds(newest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending
        let spansOlderSide = (compareArchiveIds(oldest, gap.olderRangeNewestArchiveId) ?? .orderedDescending) != .orderedDescending &&
            (compareArchiveIds(newest, gap.olderRangeNewestArchiveId) ?? .orderedAscending) != .orderedAscending
        return oldestIsOlderSide || newestIsOlderSide || spansOlderSide
    }

    private static func containsNewerSide(
        of gap: RegularChatArchiveGap,
        oldest: String,
        newest: String
    ) -> Bool {
        let oldestIsNewerSide = (compareArchiveIds(oldest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        let newestIsNewerSide = (compareArchiveIds(newest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        let spansNewerSide = (compareArchiveIds(oldest, gap.newerRangeOldestArchiveId) ?? .orderedDescending) != .orderedDescending &&
            (compareArchiveIds(newest, gap.newerRangeOldestArchiveId) ?? .orderedAscending) != .orderedAscending
        return oldestIsNewerSide || newestIsNewerSide || spansNewerSide
    }
}

extension ChatLocalHistoryPageProvider: ChatScrollBoundaryLocalHistoryAvailabilityProviding {
    func hasOlderLocalPage(before boundary: ChatTimelineBoundary) -> Bool {
        older(before: boundary, limit: 1).isNotEmpty
    }

    func hasNewerLocalPage(after boundary: ChatTimelineBoundary) -> Bool {
        newer(after: boundary, limit: 1).isNotEmpty
    }
}

extension ChatViewController {
    internal var chatTimelineConversationKey: ChatTimelineConversationKey {
        ChatTimelineConversationKey(
            owner: owner,
            jid: jid,
            conversationType: conversationType
        )
    }

    internal func invalidateScrollBoundaryAvailabilityCache() {
        scrollBoundaryAvailabilityCache.invalidate()
    }

    internal func refreshScrollBoundaryAvailabilityCache(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshScrollBoundaryAvailabilityCache(reason: reason)
            }
            return
        }

        let conversationKey = chatTimelineConversationKey
        let normalizedState = virtualTimelineState.normalized(
            owner: conversationKey.owner,
            jid: conversationKey.jid,
            conversationType: conversationKey.conversationType
        )

        do {
            let provider = ChatLocalHistoryPageProvider(
                realm: try WRealm.safe(),
                owner: conversationKey.owner,
                jid: conversationKey.jid,
                conversationType: conversationKey.conversationType
            )
            scrollBoundaryAvailabilityCache.refresh(
                conversationKey: conversationKey,
                timelineState: normalizedState,
                archiveState: loadChatArchiveStateSnapshot(),
                provider: provider,
                hasConfirmedArchiveEndThisSession: hasConfirmedArchiveEndThisSession,
                hasUsedArchiveEndVerificationProbe: hasUsedArchiveEndVerificationProbe
            )
            if let availability = scrollBoundaryAvailabilityCache.availability(for: conversationKey) {
                ChatArchiveDebugTrace.log("scrollBoundaryAvailabilityCacheRefresh", [
                    ("owner", owner),
                    ("jid", jid),
                    ("conversationType", conversationType.rawValue),
                    ("reason", reason),
                    ("localOlder", availability.hasLocalOlderPage),
                    ("localNewer", availability.hasLocalNewerPage),
                    ("gapAbove", availability.hasKnownArchiveGapAbove),
                    ("gapBelow", availability.hasKnownArchiveGapBelow),
                    ("remoteOlder", availability.hasRemoteOlderPage),
                    ("remoteNewer", availability.hasRemoteNewerPage),
                    ("remoteInFlight", availability.isRemotePageInFlight),
                    ("residentCount", normalizedState.residentPrimaryKeys.count)
                ])
            }
        } catch {
            invalidateScrollBoundaryAvailabilityCache()
            ChatArchiveDebugTrace.log("scrollBoundaryAvailabilityCacheRefreshError", [
                ("owner", owner),
                ("jid", jid),
                ("conversationType", conversationType.rawValue),
                ("reason", reason),
                ("error", error.localizedDescription)
            ])
        }
    }
}
