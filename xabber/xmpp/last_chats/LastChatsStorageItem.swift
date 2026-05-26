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
//    @objc dynamic var isMuted: Bool = false
    @objc dynamic var isBlocked: Bool = false // TODO: make deprecated
    
    @objc dynamic var draftMessage: String? = nil
    
//    @objc dynamic var groupchatRef: GroupChatStorageItem? = nil
//    @objc dynamic var isGroupchat: Bool = false
    @objc dynamic var groupchatMyId: String? = nil
    
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

struct RegularChatArchiveIDRange: Codable, Equatable {
    let oldestArchiveId: String
    let newestArchiveId: String
}

struct RegularChatArchiveGap: Codable, Equatable {
    let olderRangeNewestArchiveId: String
    let newerRangeOldestArchiveId: String
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

    static func genPrimary(jid: String, owner: String) -> String {
        return [jid, owner, ClientSynchronizationManager.ConversationType.regular.rawValue].prp()
    }

    @discardableResult
    static func ensure(owner: String, jid: String, in realm: Realm) -> RegularChatArchiveSyncStateStorageItem {
        let primary = genPrimary(jid: jid, owner: owner)
        if let existing = realm.object(ofType: RegularChatArchiveSyncStateStorageItem.self, forPrimaryKey: primary) {
            return existing
        }

        let state = RegularChatArchiveSyncStateStorageItem()
        state.primary = primary
        state.owner = owner
        state.jid = jid
        state.conversationType = .regular
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

    func mergeLoadedRange(first: String, last: String) {
        guard let range = Self.orderedRange(first: first, last: last) else {
            return
        }

        var ranges = loadedRanges + [range]
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

        loadedRanges = merged
        recomputeBoundsAndGaps()
    }

    func recordKnownNewerGap(to snapshotArchiveId: String) {
        guard let snapshotArchiveId = Self.normalizedArchiveId(snapshotArchiveId),
              let newestLoadedArchiveId = newestLoadedArchiveId,
              (isArchiveId(snapshotArchiveId, newerThan: newestLoadedArchiveId) ?? false) else {
            return
        }

        var gaps = knownGaps
        let gap = RegularChatArchiveGap(
            olderRangeNewestArchiveId: newestLoadedArchiveId,
            newerRangeOldestArchiveId: snapshotArchiveId
        )
        if !gaps.contains(gap) {
            gaps.append(gap)
        }
        knownGaps = gaps
    }

    func containsArchiveId(_ archiveId: String?) -> Bool {
        guard let archiveId = Self.normalizedArchiveId(archiveId) else {
            return false
        }
        return loadedRanges.contains { range in
            let lower = compareArchiveIds(archiveId, range.oldestArchiveId) ?? .orderedAscending
            let upper = compareArchiveIds(archiveId, range.newestArchiveId) ?? .orderedDescending
            return lower != .orderedAscending && upper != .orderedDescending
        }
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
}
