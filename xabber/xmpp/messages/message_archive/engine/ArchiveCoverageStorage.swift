import Foundation
import RealmSwift

final class ConversationArchiveCoverageStorageItem: Object {
    override static func primaryKey() -> String? {
        "primary"
    }

    override static func indexedProperties() -> [String] {
        ["owner", "jid", "conversationType_"]
    }

    @objc dynamic var primary: String = ""
    @objc dynamic var owner: String = ""
    @objc dynamic var jid: String = ""
    @objc dynamic var conversationType_: String = ClientSynchronizationManager.ConversationType.regular.rawValue
    @objc dynamic var segmentsJSON: String = "[]"
    @objc dynamic var coverageGeneration: Int64 = 0
    @objc dynamic var lastObservedXEPSYNCFingerprint: String? = nil
    @objc dynamic var createdAt: Date = Date()
    @objc dynamic var updatedAt: Date = Date()

    var conversationType: ClientSynchronizationManager.ConversationType {
        get {
            ClientSynchronizationManager.ConversationType(rawValue: conversationType_) ?? .regular
        }
        set {
            conversationType_ = newValue.rawValue
        }
    }

    var segments: [ArchiveCoverageSegment] {
        get {
            guard let data = segmentsJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([ArchiveCoverageSegment].self, from: data) else {
                return []
            }
            return ArchiveCoverageReducer.normalized(decoded)
        }
        set {
            segmentsJSON = Self.encodeSegments(ArchiveCoverageReducer.normalized(newValue))
        }
    }

    static func genPrimary(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> String {
        RegularChatArchiveSyncStateStorageItem.genPrimary(
            jid: jid,
            owner: owner,
            conversationType: conversationType
        )
    }

    @discardableResult
    static func ensure(
        key: ArchiveConversationKey,
        in realm: Realm
    ) -> ConversationArchiveCoverageStorageItem {
        let primary = genPrimary(
            owner: key.owner,
            jid: key.jid,
            conversationType: key.conversationType
        )
        if let existing = realm.object(
            ofType: ConversationArchiveCoverageStorageItem.self,
            forPrimaryKey: primary
        ) {
            return existing
        }
        let item = ConversationArchiveCoverageStorageItem()
        item.primary = primary
        item.owner = key.owner
        item.jid = key.jid
        item.conversationType = key.conversationType
        realm.add(item, update: .modified)
        return item
    }

    /// Legacy fields are a write-only compatibility view. Archive admission
    /// must read `ConversationArchiveCoverageStorageItem` exclusively.
    func projectCompatibility(in realm: Realm) {
        let verified = segments.filter(\.isVerified)
        guard verified.isNotEmpty else { return }

        let legacy = RegularChatArchiveSyncStateStorageItem.ensure(
            owner: owner,
            jid: jid,
            conversationType: conversationType,
            in: realm
        )
        legacy.loadedRanges = verified.map {
            RegularChatArchiveIDRange(
                oldestArchiveId: $0.oldest.rawValue,
                newestArchiveId: $0.newest.rawValue
            )
        }
        legacy.olderArchiveEndReached = verified.contains(where: { $0.reachesArchiveStart })
        legacy.newerLiveEdgeReached = verified.contains(where: { $0.reachesLiveEdge })
        legacy.recomputeBoundsAndGaps()

        if let chat = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary) {
            chat.isSynced = true
            chat.isInitialArchiveLoaded = true
            chat.fullArchiveLoaded = legacy.olderArchiveEndReached
            chat.lastLoadedMessageHistoryId = legacy.oldestLoadedArchiveId
        }
    }

    static func provisionalSegmentsJSON(
        legacyRangesJSON: String,
        reachesArchiveStart: Bool,
        reachesLiveEdge: Bool,
        fingerprint: String
    ) -> String {
        guard let data = legacyRangesJSON.data(using: .utf8),
              let ranges = try? JSONDecoder().decode([RegularChatArchiveIDRange].self, from: data) else {
            return "[]"
        }
        let valid = ranges.compactMap { range -> ArchiveCoverageSegment? in
            guard let oldest = ArchiveCursor(rawValue: range.oldestArchiveId),
                  let newest = ArchiveCursor(rawValue: range.newestArchiveId) else {
                return nil
            }
            return ArchiveCoverageSegment(
                oldest: oldest,
                newest: newest,
                reachesArchiveStart: false,
                reachesLiveEdge: false,
                fingerprint: fingerprint,
                isVerified: false
            )
        }
        let normalized = ArchiveCoverageReducer.normalized(valid)
        let marked = normalized.enumerated().compactMap { index, segment in
            ArchiveCoverageSegment(
                oldest: segment.oldest,
                newest: segment.newest,
                reachesArchiveStart: reachesArchiveStart && index == 0,
                reachesLiveEdge: reachesLiveEdge && index == normalized.count - 1,
                fingerprint: segment.fingerprint,
                isVerified: false
            )
        }
        return encodeSegments(marked)
    }

    private static func encodeSegments(_ segments: [ArchiveCoverageSegment]) -> String {
        guard let data = try? JSONEncoder().encode(segments),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}
