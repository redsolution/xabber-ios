import Foundation
import CryptoKit
import os.signpost

enum ArchiveEngineSignpostPhase {
    case queued
    case transport
    case final
    case persistence
    case proof
    case uikitApply
    case skeletonDuration
    case duplicateJoin
    case prefetchResult
    case retry
    case searchPage

    fileprivate var name: StaticString {
        switch self {
        case .queued: return "archive.queued"
        case .transport: return "archive.transport"
        case .final: return "archive.final"
        case .persistence: return "archive.persistence"
        case .proof: return "archive.proof"
        case .uikitApply: return "archive.uikit_apply"
        case .skeletonDuration: return "archive.skeleton_duration"
        case .duplicateJoin: return "archive.duplicate_join"
        case .prefetchResult: return "archive.prefetch_result"
        case .retry: return "archive.retry"
        case .searchPage: return "archive.search_page"
        }
    }
}

/// Archive telemetry deliberately exposes only numeric process-local counters.
/// Account, JID, query, cursor, message identifiers and search text never cross
/// this boundary.
enum ArchiveEngineObservability {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "org.xabber",
        category: "ArchiveEngine"
    )

    static func event(
        _ phase: ArchiveEngineSignpostPhase,
        value: Int = 0,
        auxiliary: Int = 0
    ) {
        os_signpost(
            .event,
            log: log,
            name: phase.name,
            "value=%{public}lld auxiliary=%{public}lld",
            Int64(clamping: value),
            Int64(clamping: auxiliary)
        )
    }
}

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

struct ArchiveCursor: Hashable, Codable, Sendable {
    let rawValue: String
    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    static func == (lhs: ArchiveCursor, rhs: ArchiveCursor) -> Bool {
        lhs.rawValue.utf8.elementsEqual(rhs.rawValue.utf8)
    }

    func hash(into hasher: inout Hasher) {
        for byte in rawValue.utf8 { hasher.combine(byte) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let cursor = ArchiveCursor(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Archive cursor must be a nonempty opaque identifier"
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

/// Allocates archive connection generations from one process-wide namespace.
/// A randomized high process seed prevents the former account-local sequence
/// (`session:1`, `session:2`, ...) from being replayed after reconstruction and
/// makes a cross-launch collision negligibly likely. The locked counter also
/// prevents reuse between Account instances in the same process.
enum ArchiveConnectionGenerationAllocator {
    private static let lock = NSLock()
    private static let minimumGeneration = UInt64(1) << 32
    private static var nextGeneration = UInt64.random(
        in: minimumGeneration...(UInt64.max >> 1)
    )

    static func take() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let generation = nextGeneration
        nextGeneration += 1
        return generation
    }
}

enum ArchiveFreshnessToken: Hashable, Codable, Sendable {
    case sessionMAM(connectionGeneration: UInt64, queryID: String)

    var fingerprint: String {
        switch self {
        case .sessionMAM(let generation, _):
            // Query identity remains part of the token so stale terminal
            // receipts can be rejected, while coverage from multiple pages
            // in one authenticated session can still merge. The generation
            // is allocated process-wide and changes on every reconnect. Its
            // randomized high launch seed makes reuse across processes
            // negligibly likely and cannot reproduce the legacy `session:1`.
            return "session:\(generation)"
        }
    }
}

/// Schema 18 -> 19 migration helper only. Its stable value imports legacy
/// ranges as provisional rows; it is never a runtime timeline freshness token.
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
    let orderedArchiveIDs: [ArchiveCursor]
    /// Cached order identity for frame-frequency scope comparisons.
    let orderedArchiveFingerprint: String
    let reachesArchiveStart: Bool
    let reachesLiveEdge: Bool
    let fingerprint: String
    let isVerified: Bool
    private let positions: [ArchiveCursor: Int]

    init?(
        orderedArchiveIDs: [ArchiveCursor],
        reachesArchiveStart: Bool,
        reachesLiveEdge: Bool,
        fingerprint: String,
        isVerified: Bool
    ) {
        guard let oldest = orderedArchiveIDs.first,
              let newest = orderedArchiveIDs.last else { return nil }
        self.init(oldest: oldest, newest: newest, reachesArchiveStart: reachesArchiveStart,
            reachesLiveEdge: reachesLiveEdge, fingerprint: fingerprint, isVerified: isVerified,
            orderedArchiveIDs: orderedArchiveIDs)
    }

    /// Endpoint-only legacy metadata never proves the identities between its
    /// endpoints. A singleton is the sole in-memory case with no missing order.
    init?(
        oldest: ArchiveCursor,
        newest: ArchiveCursor,
        reachesArchiveStart: Bool,
        reachesLiveEdge: Bool,
        fingerprint: String,
        isVerified: Bool,
        orderedArchiveIDs: [ArchiveCursor]? = nil
    ) {
        let fingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else { return nil }
        let ledger = orderedArchiveIDs ?? (oldest == newest ? [oldest] : [])
        guard ledger.isEmpty || (ledger.first == oldest && ledger.last == newest),
              Set(ledger).count == ledger.count else { return nil }
        self.oldest = oldest
        self.newest = newest
        self.orderedArchiveIDs = ledger
        self.orderedArchiveFingerprint = Self.orderingFingerprint(ledger)
        self.positions = Dictionary(uniqueKeysWithValues: ledger.enumerated().map { ($0.element, $0.offset) })
        self.reachesArchiveStart = reachesArchiveStart
        self.reachesLiveEdge = reachesLiveEdge
        self.fingerprint = fingerprint
        self.isVerified = isVerified && !ledger.isEmpty
    }

    static func == (lhs: ArchiveCoverageSegment, rhs: ArchiveCoverageSegment) -> Bool {
        lhs.oldest == rhs.oldest && lhs.newest == rhs.newest &&
            lhs.orderedArchiveIDs.count == rhs.orderedArchiveIDs.count &&
            lhs.orderedArchiveFingerprint == rhs.orderedArchiveFingerprint &&
            lhs.reachesArchiveStart == rhs.reachesArchiveStart && lhs.reachesLiveEdge == rhs.reachesLiveEdge &&
            lhs.fingerprint == rhs.fingerprint && lhs.isVerified == rhs.isVerified
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(oldest)
        hasher.combine(newest)
        hasher.combine(orderedArchiveIDs.count)
        hasher.combine(orderedArchiveFingerprint)
        hasher.combine(reachesArchiveStart)
        hasher.combine(reachesLiveEdge)
        hasher.combine(fingerprint)
        hasher.combine(isVerified)
    }

    private static func orderingFingerprint(_ ids: [ArchiveCursor]) -> String {
        var hash = SHA256()
        var count = UInt64(ids.count).bigEndian
        withUnsafeBytes(of: &count) { hash.update(data: Data($0)) }
        for id in ids {
            let bytes = Data(id.rawValue.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func index(of cursor: ArchiveCursor) -> Int? { positions[cursor] }
    func contains(_ cursor: ArchiveCursor) -> Bool { positions[cursor] != nil }

    func isBefore(_ lhs: ArchiveCursor, _ rhs: ArchiveCursor) -> Bool {
        guard let left = positions[lhs], let right = positions[rhs] else { return false }
        return left < right
    }

    func containsSegment(_ other: ArchiveCoverageSegment) -> Bool {
        guard !other.orderedArchiveIDs.isEmpty, let offset = positions[other.oldest],
              offset + other.orderedArchiveIDs.count <= orderedArchiveIDs.count else { return false }
        return orderedArchiveIDs[offset..<(offset + other.orderedArchiveIDs.count)]
            .elementsEqual(other.orderedArchiveIDs)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let oldest = try container.decode(ArchiveCursor.self, forKey: .oldest)
        let newest = try container.decode(ArchiveCursor.self, forKey: .newest)
        let ordering = try container.decodeIfPresent([ArchiveCursor].self, forKey: .orderedArchiveIDs)
        let storedVerified = try container.decode(Bool.self, forKey: .isVerified)
        guard let segment = ArchiveCoverageSegment(
            oldest: oldest, newest: newest,
            reachesArchiveStart: try container.decode(Bool.self, forKey: .reachesArchiveStart),
            reachesLiveEdge: try container.decode(Bool.self, forKey: .reachesLiveEdge),
            fingerprint: try container.decode(String.self, forKey: .fingerprint),
            isVerified: ordering?.isEmpty == false && storedVerified,
            orderedArchiveIDs: ordering ?? []
        ) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid ordered archive coverage segment"))
        }
        self = segment
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(oldest, forKey: .oldest)
        try container.encode(newest, forKey: .newest)
        try container.encode(orderedArchiveIDs, forKey: .orderedArchiveIDs)
        try container.encode(reachesArchiveStart, forKey: .reachesArchiveStart)
        try container.encode(reachesLiveEdge, forKey: .reachesLiveEdge)
        try container.encode(fingerprint, forKey: .fingerprint)
        try container.encode(isVerified, forKey: .isVerified)
    }

    private enum CodingKeys: String, CodingKey {
        case oldest, newest, orderedArchiveIDs, reachesArchiveStart, reachesLiveEdge, fingerprint, isVerified
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
           let olderIndex = segments.firstIndex(where: { $0.newest == olderBoundary && compatible($0, incoming) }),
           let newerIndex = segments.firstIndex(where: { $0.oldest == newerBoundary && compatible($0, incoming) }),
           olderIndex != newerIndex,
           let first = concatenate(segments[olderIndex], incoming),
           let merged = concatenate(first, segments[newerIndex]) {
            for index in [olderIndex, newerIndex].sorted(by: >) { segments.remove(at: index) }
            segments.insert(merged, at: min(olderIndex, segments.count))
            return normalized(segments)
        }
        if let adjacency {
            for index in segments.indices where compatible(segments[index], incoming) {
                let adjacent = segments[index]
                let merged: ArchiveCoverageSegment?
                switch adjacency {
                case .older(let boundary) where adjacent.oldest == boundary:
                    merged = concatenate(incoming, adjacent)
                case .newer(let boundary) where adjacent.newest == boundary:
                    merged = concatenate(adjacent, incoming)
                default:
                    merged = nil
                }
                if let merged {
                    segments[index] = merged
                    return normalized(segments)
                }
            }
        }
        segments.append(incoming)
        return normalized(segments)
    }

    /// Disjoint opaque ledgers have no known relative order. A gap may only
    /// originate from an explicitly bounded request, never from UID arithmetic.
    static func gaps(in segments: [ArchiveCoverageSegment]) -> [ArchiveCoverageGap] { [] }

    static func containsVerifiedWindow(
        oldest: ArchiveCursor,
        newest: ArchiveCursor,
        fingerprint: String,
        segments: [ArchiveCoverageSegment]
    ) -> Bool {
        segments.contains { segment in
            guard segment.isVerified, segment.fingerprint == fingerprint,
                  let lower = segment.index(of: oldest), let upper = segment.index(of: newest) else { return false }
            return lower <= upper
        }
    }

    static func hasConflictingOverlap(
        _ incoming: ArchiveCoverageSegment, with existing: [ArchiveCoverageSegment]
    ) -> Bool {
        existing.contains { segment in
            compatible(segment, incoming) &&
                !Set(segment.orderedArchiveIDs).isDisjoint(with: incoming.orderedArchiveIDs) &&
                overlappingUnion(segment, incoming) == nil
        }
    }

    static func normalized(_ segments: [ArchiveCoverageSegment]) -> [ArchiveCoverageSegment] {
        var result: [ArchiveCoverageSegment] = []
        for original in segments {
            var incoming = original
            var index = 0
            while index < result.count {
                if let merged = overlappingUnion(result[index], incoming) {
                    incoming = merged
                    result.remove(at: index)
                    index = 0
                } else {
                    index += 1
                }
            }
            result.append(incoming)
        }
        return result
    }

    private static func compatible(_ lhs: ArchiveCoverageSegment, _ rhs: ArchiveCoverageSegment) -> Bool {
        lhs.fingerprint == rhs.fingerprint && lhs.isVerified == rhs.isVerified &&
            !lhs.orderedArchiveIDs.isEmpty && !rhs.orderedArchiveIDs.isEmpty
    }

    private static func merged(
        _ ids: [ArchiveCursor], _ lhs: ArchiveCoverageSegment, _ rhs: ArchiveCoverageSegment
    ) -> ArchiveCoverageSegment? {
        ArchiveCoverageSegment(orderedArchiveIDs: ids,
            reachesArchiveStart: lhs.reachesArchiveStart || rhs.reachesArchiveStart,
            reachesLiveEdge: lhs.reachesLiveEdge || rhs.reachesLiveEdge,
            fingerprint: lhs.fingerprint, isVerified: lhs.isVerified)
    }

    private static func concatenate(
        _ older: ArchiveCoverageSegment, _ newer: ArchiveCoverageSegment
    ) -> ArchiveCoverageSegment? {
        guard compatible(older, newer),
              Set(older.orderedArchiveIDs).isDisjoint(with: newer.orderedArchiveIDs) else { return nil }
        return merged(older.orderedArchiveIDs + newer.orderedArchiveIDs, older, newer)
    }

    private static func overlappingUnion(
        _ lhs: ArchiveCoverageSegment, _ rhs: ArchiveCoverageSegment
    ) -> ArchiveCoverageSegment? {
        guard compatible(lhs, rhs) else { return nil }
        if let offset = lhs.index(of: rhs.oldest) {
            let overlap = min(lhs.orderedArchiveIDs.count - offset, rhs.orderedArchiveIDs.count)
            guard lhs.orderedArchiveIDs[offset..<(offset + overlap)]
                .elementsEqual(rhs.orderedArchiveIDs.prefix(overlap)) else { return nil }
            let ids = lhs.orderedArchiveIDs + rhs.orderedArchiveIDs.dropFirst(overlap)
            return merged(Array(ids), lhs, rhs)
        }
        if rhs.contains(lhs.oldest) { return overlappingUnion(rhs, lhs) }
        return nil
    }
}

struct ArchiveWindowSnapshot: Hashable, Codable, Sendable {
    let messagePrimaryIDs: [String]
    let target: ArchiveWindowLocator
    let verifiedSegment: ArchiveCoverageSegment
    let coverageGeneration: UInt64
    let freshnessToken: ArchiveFreshnessToken
}

/// Proof that one already-persisted live message belongs to a freshly
/// materialized latest window. This is deliberately separate from
/// `ArchiveWindowState`: accepting it must never replace the controller's
/// current target or turn a live insert into a target jump.
struct ArchiveLiveEdgeAdmission: Hashable, Codable, Sendable {
    let conversation: ArchiveConversationKey
    let primaryID: String
    let latestWindow: ArchiveWindowSnapshot
    let presentationIntent: ArchiveIntentDescriptor
}

/// Presentation-only proof that an outgoing row was durably created by the
/// local sender. Unlike `ArchiveLiveEdgeAdmission`, this value does not extend
/// archive coverage; the later numeric receipt reconciles the same primary.
struct ChatTimelineLocalOutgoingAdmission: Hashable, Sendable {
    let conversation: ArchiveConversationKey
    let primaryID: String
}

enum ArchiveSkeletonReason: Hashable, Codable, Sendable {
    case opening
    case offline
    case staleFingerprint
    case unverifiedCoverage
    case boundaryGap
    case loadingTarget
}

enum ArchiveFailureRecoveryAction: String, Hashable, Codable, Sendable {
    case retry
    case recoverAccount
    case showLatest
}

struct ArchiveRetryableFailure: Hashable, Codable, Sendable {
    let message: String
    let retryCount: Int
    let canRetry: Bool
    let recoveryAction: ArchiveFailureRecoveryAction

    init(
        message: String,
        retryCount: Int,
        canRetry: Bool,
        recoveryAction: ArchiveFailureRecoveryAction = .retry
    ) {
        self.message = message
        self.retryCount = retryCount
        self.canRetry = canRetry
        self.recoveryAction = recoveryAction
    }
}

enum ArchiveWindowState: Hashable, Codable, Sendable {
    case skeleton(reason: ArchiveSkeletonReason, target: ArchiveWindowLocator)
    case verified(ArchiveWindowSnapshot)
    case authoritativeEmpty(target: ArchiveWindowLocator, freshnessToken: ArchiveFreshnessToken)
    case retryableFailure(ArchiveRetryableFailure, target: ArchiveWindowLocator)
}

struct ArchiveWindowActivity: Hashable, Codable, Sendable {
    let activeBoundaryRequestCount: Int

    init(activeBoundaryRequestCount: Int) {
        self.activeBoundaryRequestCount = max(0, activeBoundaryRequestCount)
    }

    static let idle = ArchiveWindowActivity(activeBoundaryRequestCount: 0)

    var isLoadingBoundary: Bool {
        activeBoundaryRequestCount > 0
    }
}

/// The request-correlated terminal for directional archive expansion.
///
/// Activity is deliberately not a terminal signal: its independent stream may
/// reach the UI before the matching verified state. A boundary consumer must
/// finish only from this outcome and, for success, after its verified window
/// wins the UIKit transaction.
enum ArchiveBoundaryTerminalResult: Hashable, Codable, Sendable {
    case succeeded
    case failed(ArchiveRetryableFailure)
    case cancelled
}

struct ArchiveBoundaryTerminalOutcome: Hashable, Codable, Sendable {
    let requestID: UUID
    let descriptor: ArchiveIntentDescriptor
    let result: ArchiveBoundaryTerminalResult
}

enum ArchivePageSizing {
    static let initial = 80
    static let history = 100
    static let search = 50
    static let anchorBefore = 30
    static let anchorAfter = 30
}

enum ArchiveSearchScope: Hashable, Sendable {
    case conversation(ArchiveConversationKey)
    case account(owner: String, conversationTypeRaw: String)

    static func account(
        owner: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ArchiveSearchScope {
        .account(
            owner: owner,
            conversationTypeRaw: conversationType.rawValue
        )
    }

    var owner: String {
        switch self {
        case .conversation(let conversation):
            return conversation.owner
        case .account(let owner, _):
            return owner
        }
    }

    var conversation: ArchiveConversationKey? {
        guard case .conversation(let conversation) = self else { return nil }
        return conversation
    }

    var jid: String? {
        conversation?.jid
    }

    var conversationType: ClientSynchronizationManager.ConversationType {
        switch self {
        case .conversation(let conversation):
            return conversation.conversationType
        case .account(_, let rawValue):
            return ClientSynchronizationManager.ConversationType(rawValue: rawValue) ?? .regular
        }
    }
}

struct ArchiveSearchIntent: Hashable, Sendable {
    let clientQueryID: String
    let scope: ArchiveSearchScope
    let query: String

    init(
        clientQueryID: String,
        conversation: ArchiveConversationKey,
        query: String
    ) {
        self.init(
            clientQueryID: clientQueryID,
            scope: .conversation(conversation),
            query: query
        )
    }

    init(
        clientQueryID: String,
        scope: ArchiveSearchScope,
        query: String
    ) {
        self.clientQueryID = clientQueryID
        self.scope = scope
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An immutable copy of the fields needed to render and navigate a search
/// result. Realm objects never cross the archive-engine actor boundary.
struct ArchiveSearchMessage: Hashable, Sendable {
    let primaryID: String
    let archiveID: String
    let messageID: String
    let owner: String
    let conversationJID: String
    let conversationTypeRaw: String
    let body: String
    let date: Date
    let outgoing: Bool
    let deliveryStateRaw: Int
    let groupAuthorID: String?
    let groupAuthorNickname: String?
    let groupAuthorAvatarURL: String?
}

struct ArchiveSearchPage: Hashable, Sendable {
    let index: Int
    let requestCursor: String?
    let continuationCursor: String?
    let messages: [ArchiveSearchMessage]
    let isComplete: Bool
}

struct ArchiveSearchSnapshot: Hashable, Sendable {
    let clientQueryID: String
    let generation: UInt64
    let query: String
    let residentPages: [ArchiveSearchPage]
    let cursorStack: [String]
    let requestAttempt: Int
    let continuationCursor: String?
    let isComplete: Bool
    let isLoading: Bool

    var residentMessages: [ArchiveSearchMessage] {
        residentPages.flatMap(\.messages)
    }

    var canRequestNextPage: Bool {
        !isComplete && !isLoading
    }
}

struct ArchiveSearchFailure: Hashable, Sendable {
    let message: String
    let canRetry: Bool
}

enum ArchiveSearchState: Hashable, Sendable {
    case loading(ArchiveSearchSnapshot)
    case results(ArchiveSearchSnapshot)
    case retryableFailure(ArchiveSearchSnapshot, ArchiveSearchFailure)
}
