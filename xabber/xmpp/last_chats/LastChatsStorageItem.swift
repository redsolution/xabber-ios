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
import RealmSwift

class LastChatsStorageItem: Object {
    
    override static func primaryKey() -> String? {
        return "primary"
    }
    
    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    
//    @objc dynamic var messageText: String = ""
    
    @objc dynamic var messageDate: Date = Date(timeIntervalSince1970: 0)
    @objc dynamic var lastReadMessageDate: Date = Date()
    
    @objc dynamic var rosterItem: RosterStorageItem? = nil
//    var rosterItem: RosterStorageItem {
//        get {
//            return self.rosterItem_ ?? RosterStorageItem()
//        } set {
//            self.rosterItem_ = newValue
//        }
//    }
    
    @objc dynamic var lastMessage: MessageStorageItem?
    
    @objc dynamic var lastMessageId: String = ""
    @objc dynamic var isSynced: Bool = true
    @objc dynamic var isInitialArchiveLoaded: Bool = false
    @objc dynamic var isHistoryGapFixedForSession: Bool = false
    @objc dynamic var isArchived: Bool = false
    
    @objc dynamic var fullArchiveLoaded: Bool = false

//  XEP-0CCC
    @objc dynamic var retractVersion: String? = nil
    @objc dynamic var mentionId: String? = nil
    @objc dynamic var lastReadId: String? = nil
    @objc dynamic var displayedId: String? = nil
    @objc dynamic var deliveredId: String? = nil
    @objc dynamic var lastLoadedMessageHistoryId: String? = nil
    @objc dynamic var unread: Int = 0
    @objc dynamic var syncUnreadCount: Int = 0
    @objc dynamic var syncUnreadAfterId: String? = nil
    @objc dynamic var syncSnapshotLastArchiveId: String? = nil
    @objc dynamic var runtimeUnreadCount: Int = 0
//    @objc dynamic var isMuted: Bool = false
    @objc dynamic var isBlocked: Bool = false // TODO: make deprecated
    
    @objc dynamic var draftMessage: String? = nil
    
    @objc dynamic var isPrereaded: Bool = false
    
    @objc dynamic var pinnedPosition: Double = 0
    @objc dynamic var isPinned: Bool = false
    
    @objc dynamic var muteExpired: Double = -1
    
    @objc dynamic var afterburnInterval: Double = -1
    @objc dynamic var afterburnIntervalLastUpdate: Double = -1
    @objc dynamic var autoDeleteTTLSeconds: Double = -1
    @objc dynamic var autoDeletePolicyVersion: Int = 0
    @objc dynamic var autoDeleteUpdatedAt: Double = -1
    @objc dynamic var autoDeleteUpdatedBy: String? = nil
    @objc dynamic var isAllHistoryLoaded: Bool = false
    @objc dynamic var isFreshNotEmptyEncryptedChat: Bool = false
    
    @objc dynamic var hasErrorInChat: Bool = false
    
    @objc dynamic var updateTS: Double = 0
    
    @objc dynamic var conversationType_: String = ClientSynchronizationManager.ConversationType.omemo.rawValue
    
    @objc dynamic var lastChatOffset: Float = 0
    @objc dynamic var lastVisibleMessagePrimary: String? = nil
    @objc dynamic var lastVisibleMessageArchivedId: String? = nil
    @objc dynamic var lastVisibleMessageId: String? = nil
    @objc dynamic var lastVisibleMessageDate: Date? = nil
    @objc dynamic var lastVisiblePositionSavedAtLastMessageId: String? = nil
    @objc dynamic var lastVisiblePositionSavedAtSnapshotLastArchiveId: String? = nil
    @objc dynamic var lastVisiblePositionUpdatedAt: Date? = nil
    
    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            return ClientSynchronizationManager
                .ConversationType(rawValue: self.conversationType_) ?? .regular
        } set {
            self.conversationType_ = newValue.rawValue
        }
    }
    
    var isAfterburnEnabled: Bool {
        get {
            return self.afterburnInterval > 0
        }
    }

    var isAutoDeleteEnabled: Bool {
        self.autoDeleteTTLSeconds > 0 || self.afterburnInterval > 0
    }

    func applyAutoDeleteTimer(_ timer: Double, updatedAt: Double, updatedBy: String?) {
        let shouldAdvancePolicyVersion = self.autoDeleteTTLSeconds != timer || self.autoDeleteUpdatedAt < 0
        self.afterburnInterval = timer
        self.afterburnIntervalLastUpdate = updatedAt
        self.autoDeleteTTLSeconds = timer
        self.autoDeleteUpdatedAt = updatedAt
        self.autoDeleteUpdatedBy = updatedBy
        if shouldAdvancePolicyVersion {
            self.autoDeletePolicyVersion += 1
        }
    }
    
    var isMuted: Bool {
        get {
//            print("mute", self.jid, Date().timeIntervalSince1970, self.muteExpired, Date().timeIntervalSince1970 < self.muteExpired)
            return Date().timeIntervalSince1970 < self.muteExpired //self.muteExpired >= 0
        }
    }

    var hasUnreadMention: Bool {
        self.conversationType == .group && (self.mentionId?.isNotEmpty ?? false)
    }
    
    override static func indexedProperties() -> [String] {
        return ["owner", "jid", "messageDate", "isArchived"]
    }
    
    @objc dynamic var chatState_: Int = 0
    var chatState: ChatStatesManager.ComposingType {
        get {
            switch self.chatState_ {
            case ChatStatesManager.ComposingType.none.rawValue: return .none
            case ChatStatesManager.ComposingType.typing.rawValue: return .typing
            case ChatStatesManager.ComposingType.voice.rawValue: return .voice
            case ChatStatesManager.ComposingType.video.rawValue: return .video
            case ChatStatesManager.ComposingType.uploadFile.rawValue: return .uploadFile
            case ChatStatesManager.ComposingType.uploadImage.rawValue: return .uploadImage
            case ChatStatesManager.ComposingType.uploadAudio.rawValue: return .uploadAudio
            default: return .none
            }
        } set {
            self.chatState_ = newValue.rawValue
        }
    }
    
    @objc dynamic var chatMarkersSupport: Bool = false
    
    static public func genPrimary(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) -> String {
        return [jid, owner, conversationType.rawValue].prp()
    }
    
    func setPrimary(withOwner owner: String) {
        self.primary = [jid, owner, conversationType.rawValue].prp()
        self.owner = owner
    }
}

enum LastChatUnreadCounter {

    static func applySynchronizationSnapshot(
        to chat: LastChatsStorageItem,
        count: Int,
        afterId: String?,
        snapshotLastArchiveId: String?,
        in realm: Realm
    ) {
        chat.syncUnreadCount = max(count, 0)
        chat.syncUnreadAfterId = normalizedId(afterId)
        chat.syncSnapshotLastArchiveId = normalizedId(snapshotLastArchiveId)
        chat.lastReadId = chat.syncUnreadAfterId
        reconcileRuntimeContributionsAfterSnapshot(for: chat, in: realm)
        refreshTotal(for: chat)
    }

    static func recordRuntimeUnread(for message: MessageStorageItem, in chat: LastChatsStorageItem) {
        guard message.countsAsRuntimeUnread,
              !message.outgoing,
              !message.isRead,
              !message.isDeleted,
              message.unreadCounterBucket == .none,
              isMessageAfterSnapshotBoundary(message, chat: chat) else {
            refreshTotal(for: chat)
            return
        }

        message.unreadCounterBucket = .runtime
        chat.runtimeUnreadCount = max(chat.runtimeUnreadCount, 0) + 1
        refreshTotal(for: chat)
    }

    static func clearAll(
        to chat: LastChatsStorageItem,
        boundaryId: String?,
        realm: Realm
    ) {
        clearRuntimeContributions(for: chat, in: realm)
        chat.syncUnreadCount = 0
        chat.runtimeUnreadCount = 0
        let normalizedBoundary = normalizedId(boundaryId)
        chat.syncUnreadAfterId = normalizedBoundary
        chat.lastReadId = normalizedBoundary
        refreshTotal(for: chat)
    }

    static func markRead(
        through message: MessageStorageItem,
        in chat: LastChatsStorageItem,
        clearWholeDialog: Bool,
        realm: Realm
    ) {
        let boundaryId = readBoundaryId(from: message)
        if clearWholeDialog {
            clearAll(to: chat, boundaryId: boundaryId, realm: realm)
            return
        }

        clearRuntimeContributions(
            for: chat,
            in: realm,
            upTo: message.date
        )

        if isMessageAtOrAfterSnapshotLast(message, chat: chat) {
            chat.syncUnreadCount = 0
            chat.syncUnreadAfterId = normalizedId(boundaryId)
            chat.lastReadId = chat.syncUnreadAfterId
        }
        refreshTotal(for: chat)
    }

    static func removeUnreadContribution(
        for message: MessageStorageItem,
        from chat: LastChatsStorageItem
    ) {
        guard message.unreadCounterBucket == .runtime else {
            refreshTotal(for: chat)
            return
        }

        message.unreadCounterBucket = .none
        chat.runtimeUnreadCount = max(chat.runtimeUnreadCount - 1, 0)
        refreshTotal(for: chat)
    }

    static func ignoreUnresolvedDisplayedMarker(on chat: LastChatsStorageItem) {
        refreshTotal(for: chat)
    }

    static func setRuntimeUnreadCount(_ count: Int, for chat: LastChatsStorageItem) {
        chat.runtimeUnreadCount = max(count, 0)
        refreshTotal(for: chat)
    }

    static func recalculateRuntimeUnreadCount(for chat: LastChatsStorageItem, in realm: Realm) {
        chat.runtimeUnreadCount = realm
            .objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND unreadCounterBucket_ == %@",
                chat.owner,
                chat.jid,
                chat.conversationType.rawValue,
                MessageStorageItem.UnreadCounterBucket.runtime.rawValue
            )
            .count
        refreshTotal(for: chat)
    }

    static func refreshTotal(for chat: LastChatsStorageItem) {
        chat.syncUnreadCount = max(chat.syncUnreadCount, 0)
        chat.runtimeUnreadCount = max(chat.runtimeUnreadCount, 0)
        chat.unread = max(0, chat.syncUnreadCount + chat.runtimeUnreadCount)
    }

    static func readBoundaryId(from message: MessageStorageItem?) -> String? {
        guard let message else { return nil }
        if let archivedId = normalizedId(message.archivedId) {
            return archivedId
        }
        return normalizedId(message.messageId)
    }

    private static func reconcileRuntimeContributionsAfterSnapshot(
        for chat: LastChatsStorageItem,
        in realm: Realm
    ) {
        let snapshotLastArchiveId = normalizedId(chat.syncSnapshotLastArchiveId)
        let runtimeMessages = realm
            .objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND unreadCounterBucket_ == %@",
                chat.owner,
                chat.jid,
                chat.conversationType.rawValue,
                MessageStorageItem.UnreadCounterBucket.runtime.rawValue
            )

        var preservedCount = 0
        runtimeMessages.forEach { message in
            if let snapshotLastArchiveId,
               archiveId(message.archivedId, isNewerThan: snapshotLastArchiveId) {
                preservedCount += 1
            } else {
                message.unreadCounterBucket = .none
            }
        }
        chat.runtimeUnreadCount = preservedCount
    }

    private static func clearRuntimeContributions(
        for chat: LastChatsStorageItem,
        in realm: Realm,
        upTo date: Date? = nil
    ) {
        var predicate = "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND unreadCounterBucket_ == %@"
        var args: [Any] = [
            chat.owner,
            chat.jid,
            chat.conversationType.rawValue,
            MessageStorageItem.UnreadCounterBucket.runtime.rawValue
        ]
        if let date {
            predicate += " AND date <= %@"
            args.append(date)
        }

        let runtimeMessages = realm
            .objects(MessageStorageItem.self)
            .filter(NSPredicate(format: predicate, argumentArray: args))

        var removed = 0
        runtimeMessages.forEach { message in
            if message.unreadCounterBucket == .runtime {
                message.unreadCounterBucket = .none
                removed += 1
            }
        }
        chat.runtimeUnreadCount = max(chat.runtimeUnreadCount - removed, 0)
    }

    private static func isMessageAfterSnapshotBoundary(
        _ message: MessageStorageItem,
        chat: LastChatsStorageItem
    ) -> Bool {
        guard let snapshotLastArchiveId = normalizedId(chat.syncSnapshotLastArchiveId) else {
            return true
        }
        return archiveId(message.archivedId, isNewerThan: snapshotLastArchiveId)
    }

    private static func isMessageAtOrAfterSnapshotLast(
        _ message: MessageStorageItem,
        chat: LastChatsStorageItem
    ) -> Bool {
        guard let snapshotLastArchiveId = normalizedId(chat.syncSnapshotLastArchiveId) else {
            return false
        }
        return archiveId(message.archivedId, isAtOrNewerThan: snapshotLastArchiveId)
    }

    private static func archiveId(_ value: String?, isNewerThan boundary: String) -> Bool {
        guard let lhs = archiveIdNumber(value),
              let rhs = archiveIdNumber(boundary) else {
            return false
        }
        return lhs > rhs
    }

    private static func archiveId(_ value: String?, isAtOrNewerThan boundary: String) -> Bool {
        guard let lhs = archiveIdNumber(value),
              let rhs = archiveIdNumber(boundary) else {
            return false
        }
        return lhs >= rhs
    }

    private static func archiveIdNumber(_ value: String?) -> Int64? {
        guard let value = normalizedId(value) else {
            return nil
        }
        return Int64(value)
    }

    private static func normalizedId(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }
        return value
    }
}

struct RegularChatArchiveIDRange: Codable, Equatable {
    let oldestArchiveId: String
    let newestArchiveId: String
}

struct RegularChatArchiveGap: Codable, Equatable {
    let olderRangeNewestArchiveId: String
    let newerRangeOldestArchiveId: String
}

enum RegularArchiveCoverageUpdateKind: Equatable, Hashable {
    case bootstrapNewest
    case pageOlder(cursorArchiveId: String?)
    case pageNewer(cursorArchiveId: String?)
    case gapRepairOlder(cursorArchiveId: String?)
    case gapRepairNewer(cursorArchiveId: String?)
    case disjointWindow
    case none

    var adjacencyCursorArchiveId: String? {
        switch self {
        case .pageOlder(let cursorArchiveId),
             .pageNewer(let cursorArchiveId),
             .gapRepairOlder(let cursorArchiveId),
             .gapRepairNewer(let cursorArchiveId):
            return RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(cursorArchiveId)
        case .bootstrapNewest, .disjointWindow, .none:
            return nil
        }
    }

    var shouldMutateCoverage: Bool {
        self != .none
    }
}

class RegularChatArchiveSyncStateStorageItem: Object {

    override static func primaryKey() -> String? {
        return "primary"
    }

    override static func indexedProperties() -> [String] {
        return ["owner", "jid", "conversationType_"]
    }

    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var conversationType_: String = ClientSynchronizationManager.ConversationType.regular.rawValue
    @objc dynamic var oldestLoadedArchiveId: String? = nil
    @objc dynamic var newestLoadedArchiveId: String? = nil
    @objc dynamic var loadedRangesJSON: String = "[]"
    @objc dynamic var knownGapsJSON: String = "[]"
    @objc dynamic var olderArchiveEndReached: Bool = false
    @objc dynamic var newerLiveEdgeReached: Bool = false
    @objc dynamic var lastSnapshotArchiveId: String? = nil
    @objc dynamic var lastSnapshotMessageId: String? = nil
    @objc dynamic var lastSnapshotSenderId: String? = nil
    @objc dynamic var lastSnapshotBodyFingerprint: String? = nil
    @objc dynamic var lastSnapshotDate: Date? = nil
    @objc dynamic var updatedAt: Date = Date()

    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            return ClientSynchronizationManager.ConversationType(rawValue: conversationType_) ?? .regular
        }
        set {
            conversationType_ = newValue.rawValue
        }
    }

    var loadedRanges: [RegularChatArchiveIDRange] {
        get {
            Self.decodeRanges(loadedRangesJSON)
        }
        set {
            loadedRangesJSON = Self.encode(newValue)
        }
    }

    var knownGaps: [RegularChatArchiveGap] {
        get {
            Self.decodeGaps(knownGapsJSON)
        }
        set {
            knownGapsJSON = Self.encode(newValue)
        }
    }

    static func genPrimary(
        jid: String,
        owner: String,
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> String {
        return [jid, owner, conversationType.rawValue].prp()
    }

    @discardableResult
    static func ensure(owner: String, jid: String, in realm: Realm) -> RegularChatArchiveSyncStateStorageItem {
        ensure(owner: owner, jid: jid, conversationType: .regular, in: realm)
    }

    @discardableResult
    static func ensure(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        in realm: Realm
    ) -> RegularChatArchiveSyncStateStorageItem {
        let primary = genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        if let existing = realm.object(ofType: RegularChatArchiveSyncStateStorageItem.self, forPrimaryKey: primary) {
            return existing
        }

        let state = RegularChatArchiveSyncStateStorageItem()
        state.primary = primary
        state.owner = owner
        state.jid = jid
        state.conversationType = conversationType
        realm.add(state, update: .modified)
        return state
    }

    static func normalizedArchiveId(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isNotEmpty else {
            return nil
        }
        return value
    }

    static func orderedRange(first: String, last: String) -> RegularChatArchiveIDRange? {
        guard let first = normalizedArchiveId(first),
              let last = normalizedArchiveId(last) else {
            return nil
        }
        let comparison = compareArchiveIds(first, last) ?? (first <= last ? .orderedAscending : .orderedDescending)
        if comparison == .orderedDescending {
            return RegularChatArchiveIDRange(oldestArchiveId: last, newestArchiveId: first)
        }
        return RegularChatArchiveIDRange(oldestArchiveId: first, newestArchiveId: last)
    }

    func mergeLoadedRange(first: String, last: String, updateKind: RegularArchiveCoverageUpdateKind) {
        guard updateKind.shouldMutateCoverage else {
            return
        }
        guard let range = Self.orderedRange(first: first, last: last) else {
            return
        }

        let currentRanges = loadedRanges
        var ranges: [RegularChatArchiveIDRange]
        if let cursorArchiveId = updateKind.adjacencyCursorArchiveId,
           let adjacencyIndex = currentRanges.firstIndex(where: { Self.range($0, contains: cursorArchiveId) }) {
            ranges = currentRanges
            let adjacentRange = currentRanges[adjacencyIndex]
            ranges[adjacencyIndex] = Self.union(adjacentRange, range)
        } else {
            ranges = currentRanges + [range]
        }

        loadedRanges = Self.normalizedRanges(ranges)
        recomputeBoundsAndGaps()
    }

    private static func normalizedRanges(_ ranges: [RegularChatArchiveIDRange]) -> [RegularChatArchiveIDRange] {
        var ranges = ranges
        ranges.sort { lhs, rhs in
            (compareArchiveIds(lhs.oldestArchiveId, rhs.oldestArchiveId) ?? .orderedAscending) == .orderedAscending
        }

        var merged: [RegularChatArchiveIDRange] = []
        for current in ranges {
            guard let previous = merged.last else {
                merged.append(current)
                continue
            }

            let overlaps = (compareArchiveIds(current.oldestArchiveId, previous.newestArchiveId) ?? .orderedDescending) != .orderedDescending
            if overlaps {
                let newest = (compareArchiveIds(current.newestArchiveId, previous.newestArchiveId) ?? .orderedAscending) == .orderedDescending
                    ? current.newestArchiveId
                    : previous.newestArchiveId
                merged[merged.count - 1] = RegularChatArchiveIDRange(
                    oldestArchiveId: previous.oldestArchiveId,
                    newestArchiveId: newest
                )
            } else {
                merged.append(current)
            }
        }

        return merged
    }

    func recordKnownNewerGap(to snapshotArchiveId: String) {
        recomputeBoundsAndGaps()
    }

    func containsArchiveId(_ archiveId: String?) -> Bool {
        guard let archiveId = Self.normalizedArchiveId(archiveId) else {
            return false
        }
        return loadedRange(containing: archiveId) != nil
    }

    func loadedRange(containing archiveId: String?) -> RegularChatArchiveIDRange? {
        guard let archiveId = Self.normalizedArchiveId(archiveId) else {
            return nil
        }
        return loadedRanges.first { Self.range($0, contains: archiveId) }
    }

    func containsArchiveIdsInSameLoadedRange(_ archiveIds: [String?]) -> Bool {
        let archiveIds = archiveIds.compactMap { Self.normalizedArchiveId($0) }
        guard let firstArchiveId = archiveIds.first else {
            return true
        }
        guard let firstRange = loadedRange(containing: firstArchiveId) else {
            return false
        }
        return archiveIds.dropFirst().allSatisfy { Self.range(firstRange, contains: $0) }
    }

    func recomputeBoundsAndGaps() {
        let ranges = loadedRanges.sorted {
            (compareArchiveIds($0.oldestArchiveId, $1.oldestArchiveId) ?? .orderedAscending) == .orderedAscending
        }
        loadedRanges = ranges
        oldestLoadedArchiveId = ranges.first?.oldestArchiveId
        newestLoadedArchiveId = ranges.last?.newestArchiveId

        var gaps: [RegularChatArchiveGap] = []
        if ranges.count > 1 {
            for index in 1..<ranges.count {
                let older = ranges[index - 1]
                let newer = ranges[index]
                if (compareArchiveIds(older.newestArchiveId, newer.oldestArchiveId) ?? .orderedAscending) == .orderedAscending {
                    gaps.append(
                        RegularChatArchiveGap(
                            olderRangeNewestArchiveId: older.newestArchiveId,
                            newerRangeOldestArchiveId: newer.oldestArchiveId
                        )
                    )
                }
            }
        }
        knownGaps = gaps
        updatedAt = Date()
    }

    private static func decodeRanges(_ json: String) -> [RegularChatArchiveIDRange] {
        guard let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([RegularChatArchiveIDRange].self, from: data)) ?? []
    }

    private static func decodeGaps(_ json: String) -> [RegularChatArchiveGap] {
        guard let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([RegularChatArchiveGap].self, from: data)) ?? []
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func range(_ range: RegularChatArchiveIDRange, contains archiveId: String) -> Bool {
        let lower = compareArchiveIds(archiveId, range.oldestArchiveId) ?? .orderedAscending
        let upper = compareArchiveIds(archiveId, range.newestArchiveId) ?? .orderedDescending
        return lower != .orderedAscending && upper != .orderedDescending
    }

    private static func union(
        _ lhs: RegularChatArchiveIDRange,
        _ rhs: RegularChatArchiveIDRange
    ) -> RegularChatArchiveIDRange {
        let oldest = (compareArchiveIds(lhs.oldestArchiveId, rhs.oldestArchiveId) ?? .orderedAscending) == .orderedDescending
            ? rhs.oldestArchiveId
            : lhs.oldestArchiveId
        let newest = (compareArchiveIds(lhs.newestArchiveId, rhs.newestArchiveId) ?? .orderedAscending) == .orderedAscending
            ? rhs.newestArchiveId
            : lhs.newestArchiveId
        return RegularChatArchiveIDRange(oldestArchiveId: oldest, newestArchiveId: newest)
    }
}
