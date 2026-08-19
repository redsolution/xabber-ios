import Foundation

struct ArchiveTransportRequest: Hashable, Sendable {
    let queryID: String
    let conversation: ArchiveConversationKey
    let locator: ArchiveWindowLocator
    let connectionGeneration: UInt64
    let pageSize: Int
    let contextBefore: Int
    let contextAfter: Int
    let proofFingerprint: String
    let isUnfiltered: Bool
    let producesContinuousCoverage: Bool
}

struct ArchiveTransportReceipt: Hashable, Sendable {
    var queryID: String
    var connectionGeneration: UInt64
    var resultArchiveIDs: [String]
    var messagePrimaryIDs: [String]
    var first: String
    var last: String
    var complete: Bool
    var cheapPageCount: Int
    var deliveredResultCount: Int
    var persistedResultCount: Int
    var intentionallyConsumedResultCount: Int
    var failedPersistenceCount: Int
    var finalReceived: Bool
}

enum ArchiveTransportValidationError: Error, Equatable, Sendable {
    case missingFinal
    case staleQuery
    case staleConnectionGeneration
    case malformedArchiveID
    case malformedBoundary
    case incompletePersistenceAccounting
    case persistenceFailure
    case nonAdvancingCursor
    case invalidDirection
}

struct ValidatedArchiveTransportPage: Hashable, Sendable {
    let chronologicalArchiveIDs: [String]
    let messagePrimaryIDs: [String]
    let segment: ArchiveCoverageSegment?
    let adjacency: ArchiveCoverageAdjacency?
    let isAuthoritativeEmpty: Bool
    let cheapPageCount: Int
    let deliveredResultCount: Int
    let requestComplete: Bool
}

struct ArchiveMaterializedAnchor: Hashable, Sendable {
    let cursor: ArchiveCursor
    let primaryID: String
}

enum ArchiveTransportReceiptValidator {
    static func validate(
        _ receipt: ArchiveTransportReceipt,
        for request: ArchiveTransportRequest
    ) throws -> ValidatedArchiveTransportPage {
        guard receipt.finalReceived else {
            throw ArchiveTransportValidationError.missingFinal
        }
        guard receipt.queryID == request.queryID else {
            throw ArchiveTransportValidationError.staleQuery
        }
        guard receipt.connectionGeneration == request.connectionGeneration else {
            throw ArchiveTransportValidationError.staleConnectionGeneration
        }
        guard receipt.failedPersistenceCount == 0 else {
            throw ArchiveTransportValidationError.persistenceFailure
        }
        let delivered = max(0, receipt.deliveredResultCount)
        let persisted = max(0, receipt.persistedResultCount)
        let consumed = max(0, receipt.intentionallyConsumedResultCount)
        guard delivered == receipt.resultArchiveIDs.count,
              persisted == receipt.messagePrimaryIDs.count,
              delivered == persisted + consumed else {
            throw ArchiveTransportValidationError.incompletePersistenceAccounting
        }

        let cursors: [ArchiveCursor]
        do {
            cursors = try receipt.resultArchiveIDs.map { rawValue in
                guard let cursor = ArchiveCursor(rawValue: rawValue) else {
                    throw ArchiveTransportValidationError.malformedArchiveID
                }
                return cursor
            }
        } catch {
            throw error
        }

        let chronological = cursors.sorted()
        let normalizedArchiveIDs = chronological.map(\.rawValue)
        let isNewestUnfilteredRequest: Bool
        if case .latest = request.locator {
            isNewestUnfilteredRequest = request.isUnfiltered
        } else {
            isNewestUnfilteredRequest = false
        }
        let authoritativeEmpty =
            isNewestUnfilteredRequest &&
            request.producesContinuousCoverage &&
            receipt.complete &&
            receipt.cheapPageCount == 0 &&
            delivered == 0 &&
            persisted == 0 &&
            consumed == 0

        guard let oldest = chronological.first,
              let newest = chronological.last else {
            return ValidatedArchiveTransportPage(
                chronologicalArchiveIDs: [],
                messagePrimaryIDs: receipt.messagePrimaryIDs,
                segment: nil,
                adjacency: nil,
                isAuthoritativeEmpty: authoritativeEmpty,
                cheapPageCount: max(0, receipt.cheapPageCount),
                deliveredResultCount: delivered,
                requestComplete: receipt.complete
            )
        }

        guard let first = ArchiveCursor(rawValue: receipt.first),
              let last = ArchiveCursor(rawValue: receipt.last),
              Set([first, last]) == Set([oldest, newest]) || oldest == newest else {
            throw ArchiveTransportValidationError.malformedBoundary
        }

        let adjacency: ArchiveCoverageAdjacency?
        var reachesArchiveStart = false
        var reachesLiveEdge = false
        switch request.locator {
        case .latest:
            reachesLiveEdge = true
            reachesArchiveStart = receipt.complete
            adjacency = nil
        case .older(let boundary):
            guard newest < boundary else {
                throw newest == boundary
                    ? ArchiveTransportValidationError.nonAdvancingCursor
                    : ArchiveTransportValidationError.invalidDirection
            }
            reachesArchiveStart = receipt.complete
            adjacency = .older(before: boundary)
        case .newer(let boundary), .firstUnread(.some(let boundary)):
            guard oldest > boundary else {
                throw oldest == boundary
                    ? ArchiveTransportValidationError.nonAdvancingCursor
                    : ArchiveTransportValidationError.invalidDirection
            }
            reachesLiveEdge = receipt.complete
            adjacency = .newer(after: boundary)
        case .gap(let olderBoundary, let newerBoundary):
            guard oldest > olderBoundary, newest < newerBoundary else {
                throw ArchiveTransportValidationError.invalidDirection
            }
            adjacency = receipt.complete
                ? .gap(
                    olderBoundary: olderBoundary,
                    newerBoundary: newerBoundary
                )
                : .older(before: newerBoundary)
        case .firstUnread(.none):
            reachesLiveEdge = true
            reachesArchiveStart = receipt.complete
            adjacency = nil
        case .archiveID, .timestamp:
            adjacency = nil
        }

        let canProduceCoverage =
            request.isUnfiltered &&
            request.producesContinuousCoverage &&
            request.locator.isContinuousArchiveWindow
        let segment = canProduceCoverage
            ? ArchiveCoverageSegment(
                oldest: oldest,
                newest: newest,
                reachesArchiveStart: reachesArchiveStart,
                reachesLiveEdge: reachesLiveEdge,
                fingerprint: request.proofFingerprint,
                isVerified: true
            )
            : nil
        return ValidatedArchiveTransportPage(
            chronologicalArchiveIDs: normalizedArchiveIDs,
            messagePrimaryIDs: receipt.messagePrimaryIDs,
            segment: segment,
            adjacency: segment == nil ? nil : adjacency,
            isAuthoritativeEmpty: false,
            cheapPageCount: max(0, receipt.cheapPageCount),
            deliveredResultCount: delivered,
            requestComplete: receipt.complete
        )
    }
}

extension ArchiveWindowLocator {
    var isContinuousArchiveWindow: Bool {
        switch self {
        case .latest, .firstUnread, .older, .newer, .gap:
            return true
        case .archiveID, .timestamp:
            return false
        }
    }
}

enum ArchiveRepositoryCommit: Hashable, Sendable {
    case verified(ArchiveWindowSnapshot)
    case authoritativeEmpty
    case materializedWithoutCoverage
    case coverageAdvanced(nextGapBoundary: ArchiveCursor)
}

enum ArchiveRepositoryAdmission: Hashable, Sendable {
    case verified(ArchiveWindowSnapshot)
    case authoritativeEmpty
}

protocol ArchiveCoverageRepository: Sendable {
    func verifyProvisionalCoverage(owner: String, fingerprint: String) async throws
    func verifiedAdmission(
        for intent: ArchiveWindowIntent,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryAdmission?
    func commit(
        _ page: ValidatedArchiveTransportPage,
        request: ArchiveTransportRequest,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveRepositoryCommit
    func commitAnchorWindow(
        intent: ArchiveWindowIntent,
        anchor: ArchiveMaterializedAnchor,
        exactPage: ValidatedArchiveTransportPage,
        olderPage: ValidatedArchiveTransportPage,
        newerPage: ValidatedArchiveTransportPage,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot
    func materializedAnchor(
        conversation: ArchiveConversationKey,
        locator: ArchiveWindowLocator,
        candidateArchiveIDs: [String]
    ) async throws -> ArchiveMaterializedAnchor?
    func extendLiveEdge(
        for intent: ArchiveWindowIntent,
        primaryID: String,
        freshnessToken: ArchiveFreshnessToken
    ) async throws -> ArchiveWindowSnapshot?
}

protocol ArchiveMessageMaterializationResolving: Sendable {
    func materializedMessagePrimaryIDs(
        conversation: ArchiveConversationKey,
        archiveIDs: [String]
    ) async throws -> [String]
}

protocol ArchiveTransport: Sendable {
    func request(
        _ request: ArchiveTransportRequest,
        priority: ArchiveIntentPriority
    ) async throws -> ArchiveTransportReceipt
    func promote(
        descriptor: ArchiveIntentDescriptor,
        to priority: ArchiveIntentPriority
    ) async
}

enum ArchiveTransportError: Error, Equatable, Sendable {
    case disconnected
    case timeout
    case storage
    case authentication
    case protocolViolation
    case malformedCursor

    var isRetryable: Bool {
        switch self {
        case .disconnected, .timeout, .storage:
            return true
        case .authentication, .protocolViolation, .malformedCursor:
            return false
        }
    }
}
