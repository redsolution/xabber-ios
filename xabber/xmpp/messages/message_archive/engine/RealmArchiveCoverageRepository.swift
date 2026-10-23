import Foundation
import RealmSwift

enum ArchiveCoverageRepositoryError: Error, Equatable, Sendable {
    case missingPersistedMessages
    case persistedMessageIdentityMismatch
    case malformedPersistedArchiveID
    case storageFailure
}

enum ArchiveCoverageCommitDiagnosticReason: Int, Sendable {
    case missingPersistedRows = 1
    case persistedMessageIdentityMismatch = 2
    case malformedPersistedArchiveID = 3
    case coverageStorageMissing = 4
    case admittedSegmentMissing = 5
    case visibleWindowEmpty = 6
    case pageMaterializationMissing = 7
}

final class RealmArchiveCoverageRepository:
    ArchiveCoverageRepository,
    ArchiveMessageMaterializationResolving,
    @unchecked Sendable {
    typealias RealmProvider = () throws -> Realm

    private let queue = DispatchQueue(label: "com.xabber.archive-coverage-repository")
    private let realmProvider: RealmProvider
    private let materializationBatchObserver: (@Sendable (Int, Int) -> Void)?

    init(realmProvider: @escaping RealmProvider = { try WRealm.safe() }) {
        self.realmProvider = realmProvider
        self.materializationBatchObserver = nil
    }

    init(
        realmProvider: @escaping RealmProvider,
        materializationBatchObserver: @escaping @Sendable (Int, Int) -> Void
    ) {
        self.realmProvider = realmProvider
        self.materializationBatchObserver = materializationBatchObserver
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
            ), storage.archiveFreshnessFingerprint == freshnessToken.fingerprint,
               storage.hasReadableCoverageMetadata else {
                return nil
            }
            switch intent.locator {
            case .latest, .firstUnread(.none):
                if Self.hasCurrentLiveTailWithoutMAMIdentity(
                    conversation: intent.conversation, in: realm
                ) {
                    return nil
                }
            default:
                break
            }
            let verified = storage.segments.filter {
                $0.isVerified && $0.fingerprint == freshnessToken.fingerprint
            }
            if verified.isEmpty, storage.segments.isEmpty,
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
            switch intent.locator {
            case .latest, .firstUnread(.none):
                if let tail = Self.currentVisibleLinkedTail(conversation: intent.conversation, in: realm),
                   let cursor = Self.archiveCursor(for: tail),
                   !segment.contains(cursor) { return nil }
            default:
                break
            }
            let primaryIDs = Self.messagePrimaryIDs(
                for: intent,
                segment: segment,
                realm: realm,
                batchObserver: self.materializationBatchObserver
            )
            guard primaryIDs.isNotEmpty else {
                return nil
            }
            if case .firstUnread(.some(let boundary)) = intent.locator {
                let rows = realm.objects(MessageStorageItem.self).filter("primary IN %@", primaryIDs)
                guard rows.contains(where: { row in
                    guard !row.outgoing, row.deleteState == .visible,
                          row.effectiveAutoDeleteExpiresAt <= 0 ||
                            row.effectiveAutoDeleteExpiresAt > Date().timeIntervalSince1970,
                          let cursor = Self.archiveCursor(for: row) else { return false }
                    return segment.isBefore(boundary, cursor)
                }) else { return nil }
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
                    storage.archiveFreshnessFingerprint = freshnessToken.fingerprint
                    storage.coverageGeneration += 1
                    storage.updatedAt = Date()
                    Self.projectAuthoritativeEmpty(storage: storage, in: realm)
                    return UInt64(max(0, storage.coverageGeneration))
                }
                _ = generation
                return .authoritativeEmpty
            }

            if let completedBoundary = try Self.commitCompletedEmptyBoundary(
                page,
                request: request,
                freshnessToken: freshnessToken,
                realm: realm,
                batchObserver: self.materializationBatchObserver
            ) {
                return completedBoundary
            }

            guard let segment = page.segment else {
                if page.deliveredResultCount == 0, page.messagePrimaryIDs.isEmpty {
                    return .noProgress
                }
                return .materializedWithoutCoverage
            }
            let isConsumedOnlyPage = page.messagePrimaryIDs.isEmpty &&
                page.deliveredResultCount > 0 &&
                page.intentionallyConsumedResultCount == page.deliveredResultCount
            guard page.messagePrimaryIDs.isNotEmpty || isConsumedOnlyPage else {
                Self.logCommitRejection(
                    .pageMaterializationMissing,
                    page: page,
                    request: request
                )
                throw ArchiveCoverageRepositoryError.missingPersistedMessages
            }
            if page.messagePrimaryIDs.isNotEmpty {
                let persistedRows = realm.objects(MessageStorageItem.self)
                    .filter("primary IN %@", page.messagePrimaryIDs)
                guard persistedRows.count == Set(page.messagePrimaryIDs.map { Data($0.utf8) }).count else {
                    Self.logCommitRejection(
                        .missingPersistedRows,
                        page: page,
                        request: request,
                        fields: [
                            ("persistedRowCount", persistedRows.count)
                        ]
                    )
                    throw ArchiveCoverageRepositoryError.missingPersistedMessages
                }
                for message in persistedRows {
                    guard message.owner == request.conversation.owner,
                          message.opponent == request.conversation.jid,
                          message.conversationType == request.conversation.conversationType else {
                        Self.logCommitRejection(
                            .persistedMessageIdentityMismatch,
                            page: page,
                            request: request,
                            fields: [
                                ("persistedRowCount", persistedRows.count)
                            ]
                        )
                        throw ArchiveCoverageRepositoryError.persistedMessageIdentityMismatch
                    }
                    guard let cursor = Self.archiveCursor(for: message),
                          segment.contains(cursor) else {
                        Self.logCommitRejection(
                            .malformedPersistedArchiveID,
                            page: page,
                            request: request,
                            fields: [
                                ("persistedRowCount", persistedRows.count)
                            ]
                        )
                        throw ArchiveCoverageRepositoryError.malformedPersistedArchiveID
                    }
                }
            }

            let generation: UInt64 = try realm.write {
                let storage = ConversationArchiveCoverageStorageItem.ensure(
                    key: request.conversation,
                    in: realm
                )
                let currentSessionSegments =
                    storage.archiveFreshnessFingerprint == freshnessToken.fingerprint
                    ? storage.segments
                    : []
                guard !ArchiveCoverageReducer.hasConflictingOverlap(segment, with: currentSessionSegments) else {
                    throw ArchiveCoverageRepositoryError.persistedMessageIdentityMismatch
                }
                storage.segments = ArchiveCoverageReducer.adding(
                    segment,
                    to: currentSessionSegments,
                    adjacency: page.adjacency
                )
                storage.archiveFreshnessFingerprint = freshnessToken.fingerprint
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
                Self.logCommitRejection(
                    .coverageStorageMissing,
                    page: page,
                    request: request
                )
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
                Self.logCommitRejection(
                    .admittedSegmentMissing,
                    page: page,
                    request: request,
                    fields: [
                        ("verifiedSegmentCount", verifiedSegments.count),
                        ("storedSegmentCount", storage.segments.count)
                    ]
                )
                throw ArchiveCoverageRepositoryError.storageFailure
            }
            let orderedPrimaryIDs = Self.messagePrimaryIDs(
                for: intent,
                segment: admittedSegment,
                realm: realm,
                batchObserver: self.materializationBatchObserver
            )
            guard orderedPrimaryIDs.isNotEmpty || isConsumedOnlyPage else {
                let rowDiagnostics = Self.visibleRowDiagnostics(
                    realm: realm,
                    messagePrimaryIDs: page.messagePrimaryIDs,
                    segment: admittedSegment
                )
                Self.logCommitRejection(
                    .visibleWindowEmpty,
                    page: page,
                    request: request,
                    fields: [
                        ("pagePersistedRowCount", rowDiagnostics.total),
                        ("pageDeletedRowCount", rowDiagnostics.deleted),
                        ("pageHiddenRowCount", rowDiagnostics.hidden),
                        ("pageMalformedCursorRowCount", rowDiagnostics.malformedCursor),
                        ("pageVisibleRowsInsideSegment", rowDiagnostics.visibleInsideSegment),
                        ("verifiedSegmentCount", verifiedSegments.count)
                    ]
                )
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

    private static func commitCompletedEmptyBoundary(
        _ page: ValidatedArchiveTransportPage,
        request: ArchiveTransportRequest,
        freshnessToken: ArchiveFreshnessToken,
        realm: Realm,
        batchObserver: (@Sendable (Int, Int) -> Void)?
    ) throws -> ArchiveRepositoryCommit? {
        guard request.isUnfiltered,
              request.producesContinuousCoverage,
              page.requestComplete,
              page.chronologicalArchiveIDs.isEmpty,
              page.messagePrimaryIDs.isEmpty,
              page.deliveredResultCount == 0,
              page.intentionallyConsumedResultCount == 0,
              request.proofFingerprint == freshnessToken.fingerprint,
              let storage = realm.object(
                ofType: ConversationArchiveCoverageStorageItem.self,
                forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                    owner: request.conversation.owner,
                    jid: request.conversation.jid,
                    conversationType: request.conversation.conversationType
                )
              ),
              storage.archiveFreshnessFingerprint == freshnessToken.fingerprint else {
            return nil
        }

        var segments = storage.segments
        let updatedSegment: ArchiveCoverageSegment
        switch request.locator {
        case .older(let boundary):
            guard let index = segments.firstIndex(where: {
                $0.isVerified &&
                    $0.fingerprint == freshnessToken.fingerprint &&
                    $0.oldest == boundary
            }), let replacement = ArchiveCoverageSegment(
                oldest: segments[index].oldest,
                newest: segments[index].newest,
                reachesArchiveStart: true,
                reachesLiveEdge: segments[index].reachesLiveEdge,
                fingerprint: segments[index].fingerprint,
                isVerified: true,
                orderedArchiveIDs: segments[index].orderedArchiveIDs
            ) else {
                throw ArchiveCoverageRepositoryError.storageFailure
            }
            segments[index] = replacement
            updatedSegment = replacement
        case .newer(let boundary), .firstUnread(.some(let boundary)):
            guard let index = segments.firstIndex(where: {
                $0.isVerified &&
                    $0.fingerprint == freshnessToken.fingerprint &&
                    $0.newest == boundary
            }), let replacement = ArchiveCoverageSegment(
                oldest: segments[index].oldest,
                newest: segments[index].newest,
                reachesArchiveStart: segments[index].reachesArchiveStart,
                reachesLiveEdge: true,
                fingerprint: segments[index].fingerprint,
                isVerified: true,
                orderedArchiveIDs: segments[index].orderedArchiveIDs
            ) else {
                throw ArchiveCoverageRepositoryError.storageFailure
            }
            segments[index] = replacement
            updatedSegment = replacement
        case .gap(let olderBoundary, let newerBoundary):
            guard let olderIndex = segments.firstIndex(where: {
                $0.isVerified &&
                    $0.fingerprint == freshnessToken.fingerprint &&
                    $0.newest == olderBoundary
            }), let newerIndex = segments.firstIndex(where: {
                $0.isVerified &&
                    $0.fingerprint == freshnessToken.fingerprint &&
                    $0.oldest == newerBoundary
            }), olderIndex != newerIndex else {
                throw ArchiveCoverageRepositoryError.storageFailure
            }
            let older = segments[olderIndex]
            let newer = segments[newerIndex]
            guard let replacement = ArchiveCoverageSegment(
                oldest: older.oldest,
                newest: newer.newest,
                reachesArchiveStart: older.reachesArchiveStart,
                reachesLiveEdge: newer.reachesLiveEdge,
                fingerprint: freshnessToken.fingerprint,
                isVerified: true,
                orderedArchiveIDs: older.orderedArchiveIDs + newer.orderedArchiveIDs
            ) else {
                throw ArchiveCoverageRepositoryError.storageFailure
            }
            for index in [olderIndex, newerIndex].sorted(by: >) {
                segments.remove(at: index)
            }
            segments.append(replacement)
            updatedSegment = replacement
        case .latest, .firstUnread(.none), .archiveID, .timestamp:
            return nil
        }

        let intent = ArchiveWindowIntent(
            conversation: request.conversation,
            locator: request.locator,
            contextBefore: request.contextBefore,
            contextAfter: request.contextAfter,
            priority: .visibleIntegrity
        )
        var primaryIDs = messagePrimaryIDs(
            for: intent,
            segment: updatedSegment,
            realm: realm,
            batchObserver: batchObserver
        )
        if primaryIDs.isEmpty {
            let fallbackLocator: ArchiveWindowLocator
            switch request.locator {
            case .newer, .firstUnread: fallbackLocator = .latest
            case .older, .gap: fallbackLocator = .older(before: updatedSegment.oldest)
            case .latest, .archiveID, .timestamp: fallbackLocator = request.locator
            }
            let fallback = ArchiveWindowIntent(conversation: request.conversation,
                locator: fallbackLocator, contextBefore: 1, contextAfter: 1, priority: .visibleIntegrity)
            primaryIDs = messagePrimaryIDs(for: fallback, segment: updatedSegment,
                realm: realm, batchObserver: batchObserver)
            if primaryIDs.count > 1 { primaryIDs = Array(primaryIDs.prefix(1)) }
        }
        guard primaryIDs.isNotEmpty else {
            throw ArchiveCoverageRepositoryError.missingPersistedMessages
        }
        let generation: UInt64 = try realm.write {
            storage.segments = segments
            storage.coverageGeneration += 1
            storage.updatedAt = Date()
            storage.projectCompatibility(in: realm)
            return UInt64(max(0, storage.coverageGeneration))
        }
        return .verified(
            ArchiveWindowSnapshot(
                messagePrimaryIDs: primaryIDs,
                target: request.locator,
                verifiedSegment: updatedSegment,
                coverageGeneration: generation,
                freshnessToken: freshnessToken
            )
        )
    }

    func materializedMessages(
        conversation: ArchiveConversationKey,
        archiveIDs: [String]
    ) async throws -> [ArchiveMaterializedMessageIdentity] {
        let requestedIDs = archiveIDs.compactMap { ArchiveCursor(rawValue: $0) }
        let positions = requestedIDs.enumerated().reduce(into: [ArchiveCursor: Int]()) {
            if $0[$1.element] == nil { $0[$1.element] = $1.offset }
        }
        let requested = Set(requestedIDs)
        guard requested.isNotEmpty else { return [] }
        return try await perform { realm in
            let materialized = realm.objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND mamArchiveId IN %@",
                    conversation.owner,
                    conversation.jid,
                    conversation.conversationType.rawValue,
                    requested.map(\.rawValue)
                )
                .compactMap { message -> (ArchiveMaterializedMessageIdentity, ArchiveCursor)? in
                    guard let cursor = Self.archiveCursor(for: message) else {
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
            let hasDuplicateArchiveIdentity = Dictionary(
                grouping: materialized,
                by: { $0.1 }
            ).values.contains { identities in
                Set(identities.map { Data($0.0.primaryID.utf8) }).count > 1
            }
            guard !hasDuplicateArchiveIdentity else {
                throw ArchiveCoverageRepositoryError.persistedMessageIdentityMismatch
            }
            return materialized
                .sorted { positions[$0.1, default: Int.max] < positions[$1.1, default: Int.max] }
                .map(\.0)
        }
    }

    func firstIncomingAnchor(
        conversation: ArchiveConversationKey,
        after boundary: ArchiveCursor,
        candidateArchiveIDs: [String]
    ) async throws -> ArchiveMaterializedAnchor? {
        guard candidateArchiveIDs.isNotEmpty else { return nil }
        let positions = candidateArchiveIDs.compactMap { ArchiveCursor(rawValue: $0) }
            .enumerated().reduce(into: [ArchiveCursor: Int]()) {
                if $0[$1.element] == nil { $0[$1.element] = $1.offset }
            }
        return try await perform { realm in
            let incoming = realm.objects(MessageStorageItem.self).filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND mamArchiveId IN %@ AND outgoing == false AND isDeleted == false AND isLocallyHiddenByReport == false",
                conversation.owner, conversation.jid, conversation.conversationTypeRaw,
                candidateArchiveIDs
            ).compactMap { message -> ArchiveMaterializedAnchor? in
                let expiresAt = message.effectiveAutoDeleteExpiresAt
                guard let cursor = Self.archiveCursor(for: message), cursor != boundary,
                      message.deleteState == .visible,
                      expiresAt <= 0 || expiresAt > Date().timeIntervalSince1970 else { return nil }
                return ArchiveMaterializedAnchor(cursor: cursor, primaryID: message.primary)
            }
            guard Dictionary(grouping: incoming, by: \.cursor).values.allSatisfy({
                Set($0.map { Data($0.primaryID.utf8) }).count == 1
            }) else {
                throw ArchiveCoverageRepositoryError.persistedMessageIdentityMismatch
            }
            return incoming.min {
                positions[$0.cursor, default: Int.max] < positions[$1.cursor, default: Int.max]
            }
        }
    }

    func materializedAnchor(
        conversation: ArchiveConversationKey,
        locator: ArchiveWindowLocator,
        candidateArchiveIDs: [String]
    ) async throws -> ArchiveMaterializedAnchor? {
        let candidates = Set(candidateArchiveIDs.compactMap(ArchiveCursor.init(rawValue:)))
        guard candidates.isNotEmpty else { return nil }
        return try await perform { realm in
            let messages = Self.messageIdentities(
                realm: realm,
                conversation: conversation,
                orderedArchiveIDs: candidateArchiveIDs.compactMap(ArchiveCursor.init(rawValue:))
            ).filter { candidates.contains($0.cursor) }
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
                let allowedArchiveIDs = Set(page.chronologicalArchiveIDs.compactMap(ArchiveCursor.init(rawValue:)))
                let rows = realm.objects(MessageStorageItem.self)
                    .filter("primary IN %@", page.messagePrimaryIDs)
                guard rows.count == Set(page.messagePrimaryIDs.map { Data($0.utf8) }).count else {
                    throw ArchiveCoverageRepositoryError.missingPersistedMessages
                }
                for row in rows {
                    guard row.owner == intent.conversation.owner,
                          row.opponent == intent.conversation.jid,
                          row.conversationType == intent.conversation.conversationType else {
                        throw ArchiveCoverageRepositoryError.persistedMessageIdentityMismatch
                    }
                    guard let archiveID = Self.archiveCursor(for: row),
                          allowedArchiveIDs.contains(archiveID) else {
                        throw ArchiveCoverageRepositoryError.malformedPersistedArchiveID
                    }
                }
            }
            guard exactPage.chronologicalArchiveIDs.contains(where: { ArchiveCursor(rawValue: $0) == anchor.cursor }),
                  exactPage.messagePrimaryIDs.contains(where: { $0.utf8.elementsEqual(anchor.primaryID.utf8) }),
                  let exactMessage = realm.object(
                    ofType: MessageStorageItem.self,
                    forPrimaryKey: anchor.primaryID
                  ),
                  exactMessage.owner == intent.conversation.owner,
                  exactMessage.opponent == intent.conversation.jid,
                  exactMessage.conversationType == intent.conversation.conversationType,
                  Self.archiveCursor(for: exactMessage) == anchor.cursor else {
                throw ArchiveCoverageRepositoryError.missingPersistedMessages
            }
            if olderPage.segment?.contains(anchor.cursor) == true {
                throw ArchiveCoverageRepositoryError.malformedPersistedArchiveID
            }
            if newerPage.segment?.contains(anchor.cursor) == true {
                throw ArchiveCoverageRepositoryError.malformedPersistedArchiveID
            }
            guard olderPage.segment != nil || olderPage.deliveredResultCount == 0,
                  newerPage.segment != nil || newerPage.deliveredResultCount == 0 else {
                throw ArchiveCoverageRepositoryError.storageFailure
            }
            let orderedIDs = (olderPage.segment?.orderedArchiveIDs ?? []) + [anchor.cursor] +
                (newerPage.segment?.orderedArchiveIDs ?? [])
            guard let compoundSegment = ArchiveCoverageSegment(
                orderedArchiveIDs: orderedIDs,
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
                let currentSessionSegments =
                    storage.archiveFreshnessFingerprint == freshnessToken.fingerprint
                    ? storage.segments
                    : []
                guard !ArchiveCoverageReducer.hasConflictingOverlap(compoundSegment, with: currentSessionSegments) else {
                    throw ArchiveCoverageRepositoryError.persistedMessageIdentityMismatch
                }
                storage.segments = ArchiveCoverageReducer.adding(
                    compoundSegment,
                    to: currentSessionSegments,
                    adjacency: nil
                )
                storage.archiveFreshnessFingerprint = freshnessToken.fingerprint
                storage.coverageGeneration += 1
                storage.updatedAt = Date()
                storage.projectCompatibility(in: realm)
                return UInt64(max(0, storage.coverageGeneration))
            }
            let primaryIDs = Self.messagePrimaryIDs(
                for: intent,
                segment: compoundSegment,
                realm: realm,
                batchObserver: self.materializationBatchObserver
            )
            guard primaryIDs.contains(where: { $0.utf8.elementsEqual(anchor.primaryID.utf8) }) else {
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
               let cursor = Self.archiveCursor(for: message),
               let storage = realm.object(
                   ofType: ConversationArchiveCoverageStorageItem.self,
                   forPrimaryKey: ConversationArchiveCoverageStorageItem.genPrimary(
                       owner: intent.conversation.owner,
                       jid: intent.conversation.jid,
                       conversationType: intent.conversation.conversationType
                   )
               ),
               storage.archiveFreshnessFingerprint == freshnessToken.fingerprint,
               storage.hasReadableCoverageMetadata else {
                return nil
            }

            let verifiedSegments = storage.segments.filter {
                $0.isVerified && $0.fingerprint == freshnessToken.fingerprint
            }
            let currentLiveEdge = verifiedSegments.last(where: { $0.reachesLiveEdge })
            let expanded: ArchiveCoverageSegment
            if let currentLiveEdge {
                let orderedIDs = currentLiveEdge.contains(cursor)
                    ? currentLiveEdge.orderedArchiveIDs : currentLiveEdge.orderedArchiveIDs + [cursor]
                guard let value = ArchiveCoverageSegment(
                    orderedArchiveIDs: orderedIDs,
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
                guard verifiedSegments.isEmpty, storage.segments.isEmpty,
                      storage.coverageGeneration > 0,
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
                realm: realm,
                batchObserver: self.materializationBatchObserver
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
                $0.isBefore($0.oldest, boundary)
            })
        case .newer(let boundary), .firstUnread(.some(let boundary)):
            return segments.first(where: {
                $0.isBefore(boundary, $0.newest)
            })
        case .firstUnread(.none):
            return segments.last(where: { $0.reachesLiveEdge })
        case .archiveID(let cursor):
            return segments.first(where: { $0.contains(cursor) })
        case .timestamp(let date):
            guard let cursor = closestCursor(
                to: date,
                realm: realm,
                conversation: conversation
            ) else { return nil }
            return segments.first(where: { $0.contains(cursor) })
        case .gap(let olderBoundary, let newerBoundary):
            return segments.first(where: {
                $0.isBefore(olderBoundary, newerBoundary)
            })
        }
    }

    private struct MessageIdentity {
        let primary: String
        let cursor: ArchiveCursor
        let date: Date
        let isVisibleIncoming: Bool
    }

    private struct VisibleRowDiagnostics {
        let total: Int
        let deleted: Int
        let hidden: Int
        let malformedCursor: Int
        let visibleInsideSegment: Int
    }

    private static func logCommitRejection(
        _ reason: ArchiveCoverageCommitDiagnosticReason,
        page: ValidatedArchiveTransportPage,
        request: ArchiveTransportRequest,
        fields: [(String, Any?)] = []
    ) {
        ChatArchiveDebugTrace.logDiagnostic(
            "archiveCoverageCommitRejected",
            context: ChatArchiveDebugTrace.DiagnosticContext(
                owner: request.conversation.owner,
                jid: request.conversation.jid,
                conversationType: request.conversation.conversationType.rawValue,
                queryID: request.queryID
            ),
            [
                ("reasonCode", reason.rawValue),
                ("locatorCode", diagnosticLocatorCode(request.locator)),
                ("requestComplete", page.requestComplete),
                ("deliveredResultCount", page.deliveredResultCount),
                ("consumedResultCount", page.intentionallyConsumedResultCount),
                ("pagePrimaryCount", page.messagePrimaryIDs.count),
                ("uniquePagePrimaryCount", Set(page.messagePrimaryIDs.map { Data($0.utf8) }).count),
                ("archiveResultCount", page.chronologicalArchiveIDs.count)
            ] + fields
        )
    }

    private static func visibleRowDiagnostics(
        realm: Realm,
        messagePrimaryIDs: [String],
        segment: ArchiveCoverageSegment
    ) -> VisibleRowDiagnostics {
        let rows = realm.objects(MessageStorageItem.self)
            .filter("primary IN %@", messagePrimaryIDs)
        var deleted = 0
        var hidden = 0
        var malformedCursor = 0
        var visibleInsideSegment = 0
        rows.forEach { message in
            if message.isDeleted {
                deleted += 1
            }
            if message.isLocallyHiddenByReport {
                hidden += 1
            }
            guard let cursor = archiveCursor(for: message) else {
                malformedCursor += 1
                return
            }
            if !message.isDeleted,
               !message.isLocallyHiddenByReport,
               segment.contains(cursor) {
                visibleInsideSegment += 1
            }
        }
        return VisibleRowDiagnostics(
            total: rows.count,
            deleted: deleted,
            hidden: hidden,
            malformedCursor: malformedCursor,
            visibleInsideSegment: visibleInsideSegment
        )
    }

    private static func archiveCursor(
        for message: MessageStorageItem
    ) -> ArchiveCursor? {
        guard message.mamArchiveId.isNotEmpty else {
            return nil
        }
        return ArchiveCursor(rawValue: message.mamArchiveId)
    }

    private static func currentVisibleLinkedTail(
        conversation: ArchiveConversationKey, in realm: Realm
    ) -> MessageStorageItem? {
        guard let chat = realm.object(ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: conversation.jid,
                owner: conversation.owner, conversationType: conversation.conversationType)),
              let message = chat.lastMessage,
              chat.owner == conversation.owner, chat.jid == conversation.jid,
              chat.conversationType == conversation.conversationType,
              message.owner == conversation.owner, message.opponent == conversation.jid,
              message.conversationType == conversation.conversationType,
              !message.isDeleted, !message.isLocallyHiddenByReport, message.deleteState == .visible,
              message.effectiveAutoDeleteExpiresAt <= 0 ||
                message.effectiveAutoDeleteExpiresAt > Date().timeIntervalSince1970 else { return nil }
        return message
    }

    private static func hasCurrentLiveTailWithoutMAMIdentity(
        conversation: ArchiveConversationKey, in realm: Realm
    ) -> Bool {
        guard let message = currentVisibleLinkedTail(conversation: conversation, in: realm) else { return false }
        return message.archivedId.isNotEmpty && message.mamArchiveId.isEmpty
    }

    private static func diagnosticLocatorCode(
        _ locator: ArchiveWindowLocator
    ) -> Int {
        switch locator {
        case .latest:
            return 1
        case .older:
            return 2
        case .newer:
            return 3
        case .firstUnread:
            return 4
        case .gap:
            return 5
        case .archiveID:
            return 6
        case .timestamp:
            return 7
        }
    }

    private static func messageIdentities(
        realm: Realm,
        conversation: ArchiveConversationKey,
        orderedArchiveIDs: [ArchiveCursor],
        batchObserver: (@Sendable (Int, Int) -> Void)? = nil
    ) -> [MessageIdentity] {
        guard !orderedArchiveIDs.isEmpty else { return [] }
        let rows = realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND mamArchiveId IN %@ AND isDeleted == false AND isLocallyHiddenByReport == false",
            conversation.owner, conversation.jid, conversation.conversationType.rawValue,
            orderedArchiveIDs.map(\.rawValue)
        )
        // Corrupt duplicate identities cannot force an unbounded hydration.
        let values = rows.prefix(orderedArchiveIDs.count + 1).compactMap { message -> MessageIdentity? in
            guard let cursor = archiveCursor(for: message) else { return nil }
            return MessageIdentity(primary: message.primary, cursor: cursor, date: message.date,
                isVisibleIncoming: !message.outgoing && message.deleteState == .visible &&
                    (message.effectiveAutoDeleteExpiresAt <= 0 ||
                        message.effectiveAutoDeleteExpiresAt > Date().timeIntervalSince1970))
        }
        batchObserver?(orderedArchiveIDs.count, values.count)
        guard Set(values.map(\.cursor)).count == values.count else { return [] }
        let positions = Dictionary(uniqueKeysWithValues: orderedArchiveIDs.enumerated().map { ($0.element, $0.offset) })
        return values.sorted { positions[$0.cursor, default: Int.max] < positions[$1.cursor, default: Int.max] }
    }

    private static func messagePrimaryIDs(
        for intent: ArchiveWindowIntent,
        segment: ArchiveCoverageSegment,
        realm: Realm,
        batchObserver: (@Sendable (Int, Int) -> Void)? = nil
    ) -> [String] {
        let ledger = segment.orderedArchiveIDs
        guard !ledger.isEmpty else { return [] }
        func scan(_ range: Range<Int>, backwards: Bool, limit: Int) -> [MessageIdentity] {
            guard limit > 0, !range.isEmpty else { return [] }
            var values: [MessageIdentity] = []
            var edge = backwards ? range.upperBound : range.lowerBound
            var previousBatchWasEmpty = false
            while values.count < limit && (backwards ? edge > range.lowerBound : edge < range.upperBound) {
                let requested = previousBatchWasEmpty ? 100 : min(100, limit - values.count)
                let count = min(requested, backwards ? edge - range.lowerBound : range.upperBound - edge)
                let batchRange = backwards ? (edge - count)..<edge : edge..<(edge + count)
                let ids = Array(ledger[batchRange])
                let batch = messageIdentities(realm: realm, conversation: intent.conversation,
                    orderedArchiveIDs: ids, batchObserver: batchObserver)
                let remaining = limit - values.count
                if backwards { values = Array(batch.suffix(remaining)) + values; edge -= count }
                else { values += batch.prefix(remaining); edge += count }
                previousBatchWasEmpty = batch.isEmpty
            }
            return values
        }
        func around(_ index: Int) -> [String] {
            (scan(0..<index, backwards: true, limit: intent.contextBefore) +
             scan(index..<(index + 1), backwards: false, limit: 1) +
             scan((index + 1)..<ledger.count, backwards: false, limit: intent.contextAfter)).map(\.primary)
        }
        switch intent.locator {
        case .latest, .firstUnread(.none):
            return scan(0..<ledger.count, backwards: true, limit: max(1, intent.contextBefore)).map(\.primary)
        case .older(let boundary):
            guard let index = segment.index(of: boundary) else { return [] }
            return (scan(0..<index, backwards: true, limit: max(1, intent.contextBefore)) +
                scan(index..<ledger.count, backwards: false, limit: intent.contextAfter)).map(\.primary)
        case .newer(let boundary), .firstUnread(.some(let boundary)):
            guard let index = segment.index(of: boundary) else { return [] }
            return (scan(0..<(index + 1), backwards: true, limit: intent.contextBefore) +
                scan((index + 1)..<ledger.count, backwards: false, limit: max(1, intent.contextAfter))).map(\.primary)
        case .archiveID(let cursor):
            guard let index = segment.index(of: cursor) else { return [] }
            return around(index)
        case .timestamp(let date):
            guard let cursor = closestCursor(to: date, realm: realm,
                conversation: intent.conversation, segment: segment),
                  let index = segment.index(of: cursor) else { return [] }
            return around(index)
        case .gap(let olderBoundary, let newerBoundary):
            guard let lower = segment.index(of: olderBoundary),
                  let upper = segment.index(of: newerBoundary), lower < upper else { return [] }
            return scan(lower..<(upper + 1), backwards: false,
                limit: min(600, max(1, intent.contextBefore + intent.contextAfter))).map(\.primary)
        }
    }

    private static func closestCursor(
        to date: Date,
        realm: Realm,
        conversation: ArchiveConversationKey,
        segment: ArchiveCoverageSegment? = nil
    ) -> ArchiveCursor? {
        var rows = realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND mamArchiveId != '' AND isDeleted == false AND isLocallyHiddenByReport == false",
            conversation.owner, conversation.jid, conversation.conversationType.rawValue)
        if let segment { rows = rows.filter("mamArchiveId IN %@", segment.orderedArchiveIDs.map(\.rawValue)) }
        let before = rows.filter("date <= %@", date).sorted(byKeyPath: "date", ascending: false).first
        let after = rows.filter("date >= %@", date).sorted(byKeyPath: "date", ascending: true).first
        return [before, after].compactMap { $0 }.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }.flatMap { archiveCursor(for: $0) }
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
