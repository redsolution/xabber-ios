import Foundation

struct ArchiveConversationKey: Hashable, Codable, Sendable {
    let owner: String
    let jid: String
    let conversationTypeRaw: String

    init(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) {
        self.owner = owner
        self.jid = jid
        self.conversationTypeRaw = conversationType.rawValue
    }

    var conversationType: ClientSynchronizationManager.ConversationType {
        ClientSynchronizationManager.ConversationType(rawValue: conversationTypeRaw) ?? .regular
    }
}

struct ArchiveCursor: Hashable, Comparable, Codable, Sendable {
    let rawValue: String
    let numericValue: UInt64

    init?(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericValue = UInt64(normalized), numericValue > 0 else {
            return nil
        }
        self.rawValue = normalized
        self.numericValue = numericValue
    }

    static func < (lhs: ArchiveCursor, rhs: ArchiveCursor) -> Bool {
        lhs.numericValue < rhs.numericValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let cursor = ArchiveCursor(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Archive cursor must be a positive UInt64"
            )
        }
        self = cursor
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum ArchiveWindowLocator: Hashable, Codable, Sendable {
    case latest
    case firstUnread(after: ArchiveCursor?)
    case archiveID(ArchiveCursor)
    case timestamp(Date)
    case older(before: ArchiveCursor)
    case newer(after: ArchiveCursor)
    case gap(olderBoundary: ArchiveCursor, newerBoundary: ArchiveCursor)
}

enum ArchiveIntentPriority: Int, Comparable, Codable, Sendable {
    case idleBackfill = 0
    case snapshotRepair = 100
    case nearEdgePrefetch = 200
    case searchCurrentPage = 300
    case target = 400
    case visibleIntegrity = 500

    static func < (lhs: ArchiveIntentPriority, rhs: ArchiveIntentPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ArchiveWindowIntent: Hashable, Codable, Sendable {
    let id: UUID
    let conversation: ArchiveConversationKey
    let locator: ArchiveWindowLocator
    let contextBefore: Int
    let contextAfter: Int
    let priority: ArchiveIntentPriority

    init(
        id: UUID = UUID(),
        conversation: ArchiveConversationKey,
        locator: ArchiveWindowLocator,
        contextBefore: Int,
        contextAfter: Int,
        priority: ArchiveIntentPriority
    ) {
        self.id = id
        self.conversation = conversation
        self.locator = locator
        self.contextBefore = max(contextBefore, 0)
        self.contextAfter = max(contextAfter, 0)
        self.priority = priority
    }

    var semanticDescriptor: ArchiveIntentDescriptor {
        ArchiveIntentDescriptor(
            conversation: conversation,
            locator: locator,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )
    }
}

struct ArchiveIntentDescriptor: Hashable, Codable, Sendable {
    let conversation: ArchiveConversationKey
    let locator: ArchiveWindowLocator
    let contextBefore: Int
    let contextAfter: Int
}

enum ArchiveFreshnessToken: Hashable, Codable, Sendable {
    case xepSync(fingerprint: String)
    case sessionMAM(connectionGeneration: UInt64, queryID: String)

    var fingerprint: String {
        switch self {
        case .xepSync(let fingerprint):
            return fingerprint
        case .sessionMAM(let generation, _):
            // Query identity remains part of the token so stale terminal
            // receipts can be rejected, while coverage from multiple pages
            // in one authenticated session can still merge. The generation
            // changes on every reconnect, so this proof is never reusable by
            // a later session.
            return "session:\(generation)"
        }
    }
}

struct ArchiveSyncFingerprint: Hashable, Codable, Sendable {
    let completedSnapshotStamp: String?
    let lastArchiveID: String?
    let lastMessageID: String?
    let unreadAfterID: String?
    let unreadCount: Int

    init(
        completedSnapshotStamp: String?,
        lastArchiveID: String?,
        lastMessageID: String?,
        unreadAfterID: String?,
        unreadCount: Int
    ) {
        self.completedSnapshotStamp = Self.normalized(completedSnapshotStamp)
        self.lastArchiveID = Self.normalized(lastArchiveID)
        self.lastMessageID = Self.normalized(lastMessageID)
        self.unreadAfterID = Self.normalized(unreadAfterID)
        self.unreadCount = max(unreadCount, 0)
    }

    var stableValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let value = String(data: data, encoding: .utf8) else {
            return "archive-sync-fingerprint-invalid"
        }
        return value
    }

    private static func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

struct ArchiveCoverageSegment: Hashable, Codable, Sendable {
    let oldest: ArchiveCursor
    let newest: ArchiveCursor
    let reachesArchiveStart: Bool
    let reachesLiveEdge: Bool
    let fingerprint: String
    let isVerified: Bool

    init?(
        oldest: ArchiveCursor,
        newest: ArchiveCursor,
        reachesArchiveStart: Bool,
        reachesLiveEdge: Bool,
        fingerprint: String,
        isVerified: Bool
    ) {
        let normalizedFingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldest <= newest, normalizedFingerprint.isNotEmpty else {
            return nil
        }
        self.oldest = oldest
        self.newest = newest
        self.reachesArchiveStart = reachesArchiveStart
        self.reachesLiveEdge = reachesLiveEdge
        self.fingerprint = normalizedFingerprint
        self.isVerified = isVerified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let oldest = try container.decode(ArchiveCursor.self, forKey: .oldest)
        let newest = try container.decode(ArchiveCursor.self, forKey: .newest)
        let reachesArchiveStart = try container.decode(Bool.self, forKey: .reachesArchiveStart)
        let reachesLiveEdge = try container.decode(Bool.self, forKey: .reachesLiveEdge)
        let fingerprint = try container.decode(String.self, forKey: .fingerprint)
        let isVerified = try container.decode(Bool.self, forKey: .isVerified)
        guard let segment = ArchiveCoverageSegment(
            oldest: oldest,
            newest: newest,
            reachesArchiveStart: reachesArchiveStart,
            reachesLiveEdge: reachesLiveEdge,
            fingerprint: fingerprint,
            isVerified: isVerified
        ) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid archive coverage segment")
            )
        }
        self = segment
    }

    private enum CodingKeys: String, CodingKey {
        case oldest
        case newest
        case reachesArchiveStart
        case reachesLiveEdge
        case fingerprint
        case isVerified
    }
}

struct ArchiveCoverageGap: Hashable, Codable, Sendable {
    let olderBoundary: ArchiveCursor
    let newerBoundary: ArchiveCursor
}

enum ArchiveCoverageAdjacency: Hashable, Codable, Sendable {
    case older(before: ArchiveCursor)
    case newer(after: ArchiveCursor)
    case gap(olderBoundary: ArchiveCursor, newerBoundary: ArchiveCursor)
}

enum ArchiveCoverageReducer {
    static func adding(
        _ incoming: ArchiveCoverageSegment,
        to existing: [ArchiveCoverageSegment],
        adjacency: ArchiveCoverageAdjacency?
    ) -> [ArchiveCoverageSegment] {
        var segments = normalized(existing)
        if case .gap(let olderBoundary, let newerBoundary) = adjacency,
           let olderIndex = segments.firstIndex(where: {
               $0.newest == olderBoundary &&
                   $0.fingerprint == incoming.fingerprint &&
                   $0.isVerified == incoming.isVerified
           }),
           let newerIndex = segments.firstIndex(where: {
               $0.oldest == newerBoundary &&
                   $0.fingerprint == incoming.fingerprint &&
                   $0.isVerified == incoming.isVerified
           }),
           olderIndex != newerIndex {
            let older = segments[olderIndex]
            let newer = segments[newerIndex]
            for index in [olderIndex, newerIndex].sorted(by: >) {
                segments.remove(at: index)
            }
            if let bridge = ArchiveCoverageSegment(
                oldest: olderBoundary,
                newest: newerBoundary,
                reachesArchiveStart: false,
                reachesLiveEdge: false,
                fingerprint: incoming.fingerprint,
                isVerified: incoming.isVerified
            ), let mergedOlder = union(older, bridge),
               let mergedGap = union(mergedOlder, incoming),
               let merged = union(mergedGap, newer) {
                segments.append(merged)
                return normalized(segments)
            }
            segments.append(contentsOf: [older, newer, incoming])
            return normalized(segments)
        }
        if let index = adjacentSegmentIndex(
            for: incoming,
            in: segments,
            adjacency: adjacency
        ) {
            let adjacent = segments.remove(at: index)
            if let merged = union(adjacent, incoming) {
                segments.append(merged)
            } else {
                segments.append(adjacent)
                segments.append(incoming)
            }
        } else {
            segments.append(incoming)
        }
        return normalized(segments)
    }

    static func verifying(
        _ segments: [ArchiveCoverageSegment],
        with fingerprint: String
    ) -> [ArchiveCoverageSegment] {
        normalized(segments.compactMap { segment in
            guard !segment.isVerified, segment.fingerprint == fingerprint else {
                return segment
            }
            return ArchiveCoverageSegment(
                oldest: segment.oldest,
                newest: segment.newest,
                reachesArchiveStart: segment.reachesArchiveStart,
                reachesLiveEdge: segment.reachesLiveEdge,
                fingerprint: segment.fingerprint,
                isVerified: true
            )
        })
    }

    static func gaps(in segments: [ArchiveCoverageSegment]) -> [ArchiveCoverageGap] {
        let sorted = normalized(segments)
        guard sorted.count > 1 else { return [] }
        return zip(sorted, sorted.dropFirst()).compactMap { older, newer in
            guard older.newest < newer.oldest else { return nil }
            return ArchiveCoverageGap(
                olderBoundary: older.newest,
                newerBoundary: newer.oldest
            )
        }
    }

    static func containsVerifiedWindow(
        oldest: ArchiveCursor,
        newest: ArchiveCursor,
        fingerprint: String,
        segments: [ArchiveCoverageSegment]
    ) -> Bool {
        guard oldest <= newest else { return false }
        return segments.contains { segment in
            segment.isVerified &&
                segment.fingerprint == fingerprint &&
                segment.oldest <= oldest &&
                segment.newest >= newest
        }
    }

    static func normalized(_ segments: [ArchiveCoverageSegment]) -> [ArchiveCoverageSegment] {
        let sorted = segments.sorted {
            if $0.oldest == $1.oldest {
                return $0.newest < $1.newest
            }
            return $0.oldest < $1.oldest
        }
        var result: [ArchiveCoverageSegment] = []
        for segment in sorted {
            guard let previous = result.last,
                  previous.newest >= segment.oldest,
                  let merged = union(previous, segment) else {
                result.append(segment)
                continue
            }
            result[result.count - 1] = merged
        }
        return result
    }

    private static func adjacentSegmentIndex(
        for incoming: ArchiveCoverageSegment,
        in segments: [ArchiveCoverageSegment],
        adjacency: ArchiveCoverageAdjacency?
    ) -> Int? {
        guard let adjacency else { return nil }
        return segments.firstIndex { segment in
            guard segment.fingerprint == incoming.fingerprint,
                  segment.isVerified == incoming.isVerified else {
                return false
            }
            switch adjacency {
            case .older(let boundary):
                return segment.oldest == boundary && incoming.newest < boundary
            case .newer(let boundary):
                return segment.newest == boundary && incoming.oldest > boundary
            case .gap:
                return false
            }
        }
    }

    private static func union(
        _ lhs: ArchiveCoverageSegment,
        _ rhs: ArchiveCoverageSegment
    ) -> ArchiveCoverageSegment? {
        guard lhs.fingerprint == rhs.fingerprint,
              lhs.isVerified == rhs.isVerified else {
            return nil
        }
        return ArchiveCoverageSegment(
            oldest: min(lhs.oldest, rhs.oldest),
            newest: max(lhs.newest, rhs.newest),
            reachesArchiveStart: lhs.reachesArchiveStart || rhs.reachesArchiveStart,
            reachesLiveEdge: lhs.reachesLiveEdge || rhs.reachesLiveEdge,
            fingerprint: lhs.fingerprint,
            isVerified: lhs.isVerified
        )
    }
}

struct ArchiveWindowSnapshot: Hashable, Codable, Sendable {
    let messagePrimaryIDs: [String]
    let target: ArchiveWindowLocator
    let verifiedSegment: ArchiveCoverageSegment
    let coverageGeneration: UInt64
    let freshnessToken: ArchiveFreshnessToken
}

enum ArchiveSkeletonReason: Hashable, Codable, Sendable {
    case opening
    case offline
    case staleFingerprint
    case unverifiedCoverage
    case boundaryGap
    case loadingTarget
}

struct ArchiveRetryableFailure: Hashable, Codable, Sendable {
    let message: String
    let retryCount: Int
    let canRetry: Bool
}

enum ArchiveWindowState: Hashable, Codable, Sendable {
    case skeleton(reason: ArchiveSkeletonReason, target: ArchiveWindowLocator)
    case verified(ArchiveWindowSnapshot)
    case authoritativeEmpty(target: ArchiveWindowLocator, freshnessToken: ArchiveFreshnessToken)
    case retryableFailure(ArchiveRetryableFailure, target: ArchiveWindowLocator)
}

enum ArchivePageSizing {
    static let initial = 80
    static let history = 100
    static let search = 50
    static let anchorBefore = 30
    static let anchorAfter = 30
}
