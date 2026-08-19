import Foundation
import RealmSwift

enum ArchiveCoverageRepositoryError: Error, Equatable, Sendable {
    case missingPersistedMessages
    case persistedMessageIdentityMismatch
    case malformedPersistedArchiveID
    case storageFailure
}

final class RealmArchiveCoverageRepository:
    ArchiveCoverageRepository,
    ArchiveMessageMaterializationResolving,
    @unchecked Sendable {
    typealias RealmProvider = () throws -> Realm

    private let queue = DispatchQueue(label: "com.xabber.archive-coverage-repository")
    private let realmProvider: RealmProvider

    init(realmProvider: @escaping RealmProvider = { try WRealm.safe() }) {
        self.realmProvider = realmProvider
    }

    func verifyProvisionalCoverage(
        owner: String,
        fingerprint: String
    ) async throws {
        try await perform { realm in
            let rows = realm.objects(ConversationArchiveCoverageStorageItem.self)
                .filter("owner == %@", owner)
            guard rows.contains(where: { $0.segments.contains(where: { !$0.isVerified }) }) else {
                return
            }
            try realm.write {
                for storage in rows {
                    let chat = realm.object(
                        ofType: LastChatsStorageItem.self,
                        forPrimaryKey: storage.primary
                    )
                    let candidate = ArchiveSyncFingerprint(
                        completedSnapshotStamp: fingerprint,
                        lastArchiveID: chat?.syncSnapshotLastArchiveId,
                        lastMessageID: chat?.lastMessageId,
                        unreadAfterID: chat?.syncUnreadAfterId,
                        unreadCount: chat?.syncUnreadCount ?? 0
                    ).stableValue
                    var didVerify = false
                    let activated = storage.segments.compactMap { segment -> ArchiveCoverageSegment? in
                        guard !segment.isVerified,
                              segment.fingerprint == candidate else {
                            return segment
                        }
                        didVerify = true
                        return ArchiveCoverageSegment(
                            oldest: segment.oldest,
                            newest: segment.newest,
                            reachesArchiveStart: segment.reachesArchiveStart,
                            reachesLiveEdge: segment.reachesLiveEdge,
                            fingerprint: fingerprint,
                            isVerified: true
                        )
                    }
                    guard didVerify else { continue }
                    storage.segments = activated
                    storage.lastObservedXEPSYNCFingerprint = fingerprint
                    storage.coverageGeneration += 1
                    storage.updatedAt = Date()
                    storage.projectCompatibility(in: realm)
                }
            }
        }
    }

    func verifiedAdmission(
        for intent: ArchiveWindowIntent,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryAdmission? {
        try await perform { realm in
            guard let storage = realm.object(
                ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                    owner: intent.conversation.owner,
                    jid: intent.conversation.jid,
                    conversationType: intent.conversation.conversationType
                )
            ), storage.lastObservedXEPSYNCFingerprint == freshnessToken.fingerprint else {
                return nil
            }
            let verified = storage.segments.filter {
                $0.isVerified && $0.fingerprint == freshnessToken.fingerprint
            }
            if verified.isEmpty,
               storage.coverageGeneration > 0,
               case .latest = intent.locator {
                return .authoritativeEmpty
            }
            guard let segment = Self.admittingSegment(
                for: intent.locator,
                segments: verified,
                realm: realm,
                conversation: intent.conversation
            ) else {
                return nil
            }
            let primaryIDs = Self.messagePrimaryIDs(
                for: intent,
                segment: segment,
                realm: realm
            )
            guard primaryIDs.isNotEmpty else {
                return nil
            }
            return .verified(
                ArchiveWindowSnapshot(
                    messagePrimaryIDs: primaryIDs,
                    target: intent.locator,
                    verifiedSegment: segment,
                    coverageGeneration: UInt64(max(0, storage.coverageGeneration)),
                    freshnessToken: freshnessToken
                )
            )
        }
    }

    func commit(
        _ page: ValidatedArchiveTransportPage,
        request: ArchiveTransportRequest,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryCommit {
        try await perform { realm in
            if page.isAuthoritativeEmpty {
                let generation: UInt64 = try realm.write {
                    let storage = ConversationArchiveCoverageStorageItem.ensure(
                        key: request.conversation,
                        in: realm
                    )
                    storage.segments = []
                    storage.lastObservedXEPSYNCFingerprint = freshnessToken.fingerprint
                    storage.coverageGeneration += 1
                    storage.updatedAt = Date()
                    Self.projectAuthoritativeEmpty(storage: storage, in: realm)
                    return UInt64(max(0, storage.coverageGeneration))
                }
                _ = generation
                return .authoritativeEmpty
            }

            guard let segment = page.segment else {
                return .materializedWithoutCoverage
            }
            let isConsumedOnlyPage = page.messagePrimaryIDs.isEmpty &&
                page.deliveredResultCount > 0 &&
                page.intentionallyConsumedResultCount == page.deliveredResultCount
            guard page.messagePrimaryIDs.isNotEmpty || isConsumedOnlyPage else {
                throw ArchiveCoverageRepositoryError.missingPersistedMessages
            }
            if page.messagePrimaryIDs.isNotEmpty {
                let persistedRows = realm.objects(MessageStorageItem.self)
                    .filter("primary IN %@", page.messagePrimaryIDs)
                guard persistedRows.count == Set(page.messagePrimaryIDs).count else {
                    throw ArchiveCoverageRepositoryError.missingPersistedMessages
                }
                for message in persistedRows {
                    guard message.owner == request.conversation.owner,
                          message.opponent == request.conversation.jid,
                          message.conversationType == request.conversation.conversationType else {
                        throw ArchiveCoverageRepositoryError.persistedMessageIdentityMismatch
                    }
                    guard let cursor = ArchiveCursor(rawValue: message.archivedId),
                          cursor >= segment.oldest,
                          cursor <= segment.newest else {
                        throw ArchiveCoverageRepositoryError.malformedPersistedArchiveID
                    }
                }
            }

            let generation: UInt64 = try realm.write {
                let storage = ConversationArchiveCoverageStorageItem.ensure(
                    key: request.conversation,
                    in: realm
                )
                storage.segments = ArchiveCoverageReducer.adding(
                    segment,
                    to: storage.segments,
                    adjacency: page.adjacency
                )
                storage.lastObservedXEPSYNCFingerprint = freshnessToken.fingerprint
                storage.coverageGeneration += 1
                storage.updatedAt = Date()
                storage.projectCompatibility(in: realm)
                return UInt64(max(0, storage.coverageGeneration))
            }
            guard let storage = realm.object(
                ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                    owner: request.conversation.owner,
                    jid: request.conversation.jid,
                    conversationType: request.conversation.conversationType
                )
            ) else {
                throw ArchiveCoverageRepositoryError.storageFailure
            }
            if case .gap = request.locator,
               !page.requestComplete,
               let nextBoundary = page.segment?.oldest {
                return .coverageAdvanced(nextGapBoundary: nextBoundary)
            }
            let intent = ArchiveWindowIntent(
                conversation: request.conversation,
                locator: request.locator,
                contextBefore: request.contextBefore,
                contextAfter: request.contextAfter,
                priority: .visibleIntegrity
            )
            let verifiedSegments = storage.segments.filter {
                $0.isVerified && $0.fingerprint == freshnessToken.fingerprint
            }
            guard let admittedSegment = Self.admittingSegment(
                for: request.locator,
                segments: verifiedSegments,
                realm: realm,
                conversation: request.conversation
            ) else {
                throw ArchiveCoverageRepositoryError.storageFailure
            }
            let orderedPrimaryIDs = Self.messagePrimaryIDs(
                for: intent,
                segment: admittedSegment,
                realm: realm
            )
            guard orderedPrimaryIDs.isNotEmpty || isConsumedOnlyPage else {
                throw ArchiveCoverageRepositoryError.missingPersistedMessages
            }
            return .verified(
                ArchiveWindowSnapshot(
                    messagePrimaryIDs: orderedPrimaryIDs,
                    target: request.locator,
                    verifiedSegment: admittedSegment,
                    coverageGeneration: generation,
                    freshnessToken: freshnessToken
                )
            )
        }
    }

    func materializedMessages(
        conversation: ArchiveConversationKey,
        archiveIDs: [String]
    ) async throws -> [ArchiveMaterializedMessageIdentity] {
        let requested = Set(archiveIDs.filter(\.isNotEmpty))
        guard requested.isNotEmpty else { return [] }
        return try await perform { realm in
            realm.objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND archivedId IN %@",
                    conversation.owner,
                    conversation.jid,
                    conversation.conversationType.rawValue,
                    Array(requested)
                )
                .compactMap { message -> (ArchiveMaterializedMessageIdentity, ArchiveCursor)? in
                    guard let cursor = ArchiveCursor(rawValue: message.archivedId) else {
                        return nil
                    }
                    return (
                        ArchiveMaterializedMessageIdentity(
                            archiveID: cursor.rawValue,
                            primaryID: message.primary
                        ),
                        cursor
                    )
                }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }
    }

    func materializedAnchor(
        conversation: ArchiveConversationKey,
        locator: ArchiveWindowLocator,
        candidateArchiveIDs: [String]
    ) async throws -> ArchiveMaterializedAnchor? {
        let candidates = Set(candidateArchiveIDs.compactMap { ArchiveCursor(rawValue: $0)?.rawValue })
        guard candidates.isNotEmpty else { return nil }
        return try await perform { realm in
            let messages = Self.messageIdentities(
                realm: realm,
                conversation: conversation
            ).filter { candidates.contains($0.cursor.rawValue) }
            let selected: MessageIdentity?
            switch locator {
            case .archiveID(let requested):
                selected = messages.first(where: { $0.cursor == requested })
            case .firstUnread(.some(let requested)):
                selected = messages.first(where: { $0.cursor == requested })
            case .timestamp(let date):
                selected = messages.min {
                    abs($0.date.timeIntervalSince(date)) <
                        abs($1.date.timeIntervalSince(date))
                }
            default:
                selected = nil
            }
            return selected.map {
                ArchiveMaterializedAnchor(cursor: $0.cursor, primaryID: $0.primary)
            }
        }
    }

    func commitAnchorWindow(
        intent: ArchiveWindowIntent,
        anchor: ArchiveMaterializedAnchor,
        exactPage: ValidatedArchiveTransportPage,
        olderPage: ValidatedArchiveTransportPage,
        newerPage: ValidatedArchiveTransportPage,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot {
        try await perform { realm in
            for page in [exactPage, olderPage, newerPage] {
                let allowedArchiveIDs = Set(page.chronologicalArchiveIDs)
                let rows = realm.objects(MessageStorageItem.self)
                    .filter("primary IN %@", page.messagePrimaryIDs)
                guard rows.count == Set(page.messagePrimaryIDs).count else {
                    throw ArchiveCoverageRepositoryError.missingPersistedMessages
                }
                for row in rows {
                    guard row.owner == intent.conversation.owner,
                          row.opponent == intent.conversation.jid,
                          row.conversationType == intent.conversation.conversationType else {
                        throw ArchiveCoverageRepositoryError.persistedMessageIdentityMismatch
                    }
                    guard let archiveID = ArchiveCursor(rawValue: row.archivedId),
                          allowedArchiveIDs.contains(archiveID.rawValue) else {
                        throw ArchiveCoverageRepositoryError.malformedPersistedArchiveID
                    }
                }
            }
            guard exactPage.chronologicalArchiveIDs.contains(anchor.cursor.rawValue),
                  exactPage.messagePrimaryIDs.contains(anchor.primaryID),
                  let exactMessage = realm.object(
                    ofType: MessageStorageItem.self,
                    forPrimaryKey: anchor.primaryID
                  ),
                  exactMessage.owner == intent.conversation.owner,
                  exactMessage.opponent == intent.conversation.jid,
                  exactMessage.conversationType == intent.conversation.conversationType,
                  ArchiveCursor(rawValue: exactMessage.archivedId) == anchor.cursor else {
                throw ArchiveCoverageRepositoryError.missingPersistedMessages
            }
            if let older = olderPage.segment, older.newest >= anchor.cursor {
                throw ArchiveCoverageRepositoryError.malformedPersistedArchiveID
            }
            if let newer = newerPage.segment, newer.oldest <= anchor.cursor {
                throw ArchiveCoverageRepositoryError.malformedPersistedArchiveID
            }
            guard olderPage.segment != nil || olderPage.deliveredResultCount == 0,
                  newerPage.segment != nil || newerPage.deliveredResultCount == 0 else {
                throw ArchiveCoverageRepositoryError.storageFailure
            }
            let oldest = olderPage.segment?.oldest ?? anchor.cursor
            let newest = newerPage.segment?.newest ?? anchor.cursor
            guard let compoundSegment = ArchiveCoverageSegment(
                oldest: oldest,
                newest: newest,
                reachesArchiveStart:
                    olderPage.segment?.reachesArchiveStart ?? olderPage.requestComplete,
                reachesLiveEdge:
                    newerPage.segment?.reachesLiveEdge ?? newerPage.requestComplete,
                fingerprint: freshnessToken.fingerprint,
                isVerified: true
            ) else {
                throw ArchiveCoverageRepositoryError.storageFailure
            }
            let generation: UInt64 = try realm.write {
                let storage = ConversationArchiveCoverageStorageItem.ensure(
                    key: intent.conversation,
                    in: realm
                )
                storage.segments = ArchiveCoverageReducer.adding(
                    compoundSegment,
                    to: storage.segments,
                    adjacency: nil
                )
                storage.lastObservedXEPSYNCFingerprint = freshnessToken.fingerprint
                storage.coverageGeneration += 1
                storage.updatedAt = Date()
                storage.projectCompatibility(in: realm)
                return UInt64(max(0, storage.coverageGeneration))
            }
            let primaryIDs = Self.messagePrimaryIDs(
                for: intent,
                segment: compoundSegment,
                realm: realm
            )
            guard primaryIDs.contains(anchor.primaryID) else {
                throw ArchiveCoverageRepositoryError.missingPersistedMessages
            }
            return ArchiveWindowSnapshot(
                messagePrimaryIDs: primaryIDs,
                target: intent.locator,
                verifiedSegment: compoundSegment,
                coverageGeneration: generation,
                freshnessToken: freshnessToken
            )
        }
    }

    func extendLiveEdge(
        for intent: ArchiveWindowIntent,
        primaryID: String,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot? {
        try await perform { realm in
            guard let message = realm.object(
                ofType: MessageStorageItem.self,
                forPrimaryKey: primaryID
            ), message.owner == intent.conversation.owner,
               message.opponent == intent.conversation.jid,
               message.conversationType == intent.conversation.conversationType,
               !message.isDeleted,
               !message.isLocallyHiddenByReport,
               let cursor = ArchiveCursor(rawValue: message.archivedId),
               let storage = realm.object(
                   ofType: ConversationArchiveCoverageStorageItem.self,
                   forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                       owner: intent.conversation.owner,
                       jid: intent.conversation.jid,
                       conversationType: intent.conversation.conversationType
                   )
               ),
               storage.lastObservedXEPSYNCFingerprint == freshnessToken.fingerprint else {
                return nil
            }

            let verifiedSegments = storage.segments.filter {
                $0.isVerified && $0.fingerprint == freshnessToken.fingerprint
            }
            let currentLiveEdge = verifiedSegments.last(where: { $0.reachesLiveEdge })
            let expanded: ArchiveCoverageSegment
            if let currentLiveEdge {
                guard cursor >= currentLiveEdge.oldest else { return nil }
                guard let value = ArchiveCoverageSegment(
                    oldest: currentLiveEdge.oldest,
                    newest: max(currentLiveEdge.newest, cursor),
                    reachesArchiveStart: currentLiveEdge.reachesArchiveStart,
                    reachesLiveEdge: true,
                    fingerprint: freshnessToken.fingerprint,
                    isVerified: true
                ) else {
                    throw ArchiveCoverageRepositoryError.storageFailure
                }
                expanded = value
            } else {
                // A durable authoritative-empty proof may be followed by the
                // first live stanza in the same authenticated session.
                guard verifiedSegments.isEmpty, storage.coverageGeneration > 0,
                      let value = ArchiveCoverageSegment(
                          oldest: cursor,
                          newest: cursor,
                          reachesArchiveStart: true,
                          reachesLiveEdge: true,
                          fingerprint: freshnessToken.fingerprint,
                          isVerified: true
                      ) else {
                    return nil
                }
                expanded = value
            }

            let generation: UInt64 = try realm.write {
                storage.segments = ArchiveCoverageReducer.adding(
                    expanded,
                    to: storage.segments,
                    adjacency: nil
                )
                storage.coverageGeneration += 1
                storage.updatedAt = Date()
                storage.projectCompatibility(in: realm)
                return UInt64(max(0, storage.coverageGeneration))
            }
            guard let admitted = Self.admittingSegment(
                for: intent.locator,
                segments: storage.segments.filter {
                    $0.isVerified && $0.fingerprint == freshnessToken.fingerprint
                },
                realm: realm,
                conversation: intent.conversation
            ) else {
                return nil
            }
            let primaryIDs = Self.messagePrimaryIDs(
                for: intent,
                segment: admitted,
                realm: realm
            )
            guard primaryIDs.isNotEmpty else { return nil }
            return ArchiveWindowSnapshot(
                messagePrimaryIDs: primaryIDs,
                target: intent.locator,
                verifiedSegment: admitted,
                coverageGeneration: generation,
                freshnessToken: freshnessToken
            )
        }
    }

    private func perform<T>(_ body: @escaping (Realm) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                autoreleasepool {
                    do {
                        continuation.resume(returning: try body(self.realmProvider()))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private static func admittingSegment(
        for locator: ArchiveWindowLocator,
        segments: [ArchiveCoverageSegment],
        realm: Realm,
        conversation: ArchiveConversationKey
    ) -> ArchiveCoverageSegment? {
        switch locator {
        case .latest:
            return segments.last(where: { $0.reachesLiveEdge })
        case .older(let boundary):
            return segments.first(where: {
                $0.oldest < boundary && $0.newest >= boundary
            })
        case .newer(let boundary), .firstUnread(.some(let boundary)):
            return segments.first(where: {
                $0.oldest <= boundary && $0.newest > boundary
            })
        case .firstUnread(.none):
            return segments.last(where: { $0.reachesLiveEdge })
        case .archiveID(let cursor):
            return segments.first(where: { $0.oldest <= cursor && $0.newest >= cursor })
        case .timestamp(let date):
            guard let cursor = closestCursor(
                to: date,
                realm: realm,
                conversation: conversation
            ) else { return nil }
            return segments.first(where: { $0.oldest <= cursor && $0.newest >= cursor })
        case .gap(let olderBoundary, let newerBoundary):
            return segments.first(where: {
                $0.oldest <= olderBoundary && $0.newest >= newerBoundary
            })
        }
    }

    private struct MessageIdentity {
        let primary: String
        let cursor: ArchiveCursor
        let date: Date
    }

    private static func messageIdentities(
        realm: Realm,
        conversation: ArchiveConversationKey
    ) -> [MessageIdentity] {
        realm.objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND archivedId != '' AND isDeleted == false AND isLocallyHiddenByReport == false",
                conversation.owner,
                conversation.jid,
                conversation.conversationType.rawValue
            )
            .compactMap { message in
                guard let cursor = ArchiveCursor(rawValue: message.archivedId) else { return nil }
                return MessageIdentity(
                    primary: message.primary,
                    cursor: cursor,
                    date: message.date
                )
            }
            .sorted { $0.cursor < $1.cursor }
    }

    private static func messagePrimaryIDs(
        for intent: ArchiveWindowIntent,
        segment: ArchiveCoverageSegment,
        realm: Realm
    ) -> [String] {
        let all = messageIdentities(realm: realm, conversation: intent.conversation)
            .filter { $0.cursor >= segment.oldest && $0.cursor <= segment.newest }
        guard all.isNotEmpty else { return [] }
        switch intent.locator {
        case .latest:
            return Array(all.suffix(max(1, intent.contextBefore))).map(\.primary)
        case .older(let boundary):
            let before = all.filter { $0.cursor < boundary }
            let atAndAfter = all.filter { $0.cursor >= boundary }
            return (
                Array(before.suffix(max(1, intent.contextBefore))) +
                Array(atAndAfter.prefix(intent.contextAfter))
            ).map(\.primary)
        case .newer(let boundary), .firstUnread(.some(let boundary)):
            let atAndBefore = all.filter { $0.cursor <= boundary }
            let after = all.filter { $0.cursor > boundary }
            return (
                Array(atAndBefore.suffix(intent.contextBefore)) +
                Array(after.prefix(max(1, intent.contextAfter)))
            ).map(\.primary)
        case .firstUnread(.none):
            return Array(all.suffix(max(1, intent.contextBefore))).map(\.primary)
        case .archiveID(let cursor):
            guard let index = all.firstIndex(where: { $0.cursor == cursor }) else { return [] }
            let lower = max(0, index - intent.contextBefore)
            let upper = min(all.count, index + intent.contextAfter + 1)
            return Array(all[lower..<upper]).map(\.primary)
        case .timestamp(let date):
            guard let target = all.enumerated().min(by: {
                abs($0.element.date.timeIntervalSince(date)) <
                    abs($1.element.date.timeIntervalSince(date))
            })?.offset else { return [] }
            let lower = max(0, target - intent.contextBefore)
            let upper = min(all.count, target + intent.contextAfter + 1)
            return Array(all[lower..<upper]).map(\.primary)
        case .gap(let olderBoundary, let newerBoundary):
            return all.filter {
                $0.cursor >= olderBoundary && $0.cursor <= newerBoundary
            }.map(\.primary)
        }
    }

    private static func closestCursor(
        to date: Date,
        realm: Realm,
        conversation: ArchiveConversationKey
    ) -> ArchiveCursor? {
        messageIdentities(realm: realm, conversation: conversation).min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }?.cursor
    }

    private static func orderedPrimaryIDs(
        _ primaryIDs: [String],
        in realm: Realm
    ) -> [String] {
        realm.objects(MessageStorageItem.self)
            .filter("primary IN %@", primaryIDs)
            .compactMap { message -> (String, ArchiveCursor)? in
                guard let cursor = ArchiveCursor(rawValue: message.archivedId) else { return nil }
                return (message.primary, cursor)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private static func projectAuthoritativeEmpty(
        storage: ConversationArchiveCoverageStorageItem,
        in realm: Realm
    ) {
        let legacy = RegularChatArchiveSyncStateStorageItem.ensure(
            owner: storage.owner,
            jid: storage.jid,
            conversationType: storage.conversationType,
            in: realm
        )
        legacy.loadedRanges = []
        legacy.olderArchiveEndReached = true
        legacy.newerLiveEdgeReached = true
        legacy.recomputeBoundsAndGaps()
        if let chat = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: storage.primary
        ) {
            chat.isSynced = true
            chat.isInitialArchiveLoaded = true
            chat.fullArchiveLoaded = true
            chat.lastLoadedMessageHistoryId = nil
        }
    }
}
