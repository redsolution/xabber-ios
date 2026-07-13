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

import Foundation
import RealmSwift

struct ChatSearchTimestampAnchor: Equatable, Sendable {
    let id: ChatSearchResult.ID
    let scope: ChatSearchResult.Scope
    let anchor: ChatSearchResult.Anchor

    static func make(
        from item: MessageStorageItem,
        scope: ChatSearchResult.Scope
    ) -> ChatSearchTimestampAnchor? {
        guard item.owner == scope.owner,
              item.opponent == scope.jid,
              item.conversationType_ == scope.conversationTypeRawValue,
              !item.isDeleted,
              !item.isLocallyHiddenByReport,
              item.deleteState_ == MessageStorageItem.DeleteState.visible.rawValue,
              item.displayAs != .system else {
            return nil
        }
        let id: ChatSearchResult.ID
        if item.archivedId.isNotEmpty {
            id = .archived(item.archivedId)
        } else if item.primary.isNotEmpty {
            id = .primary(item.primary)
        } else {
            return nil
        }
        return ChatSearchTimestampAnchor(
            id: id,
            scope: scope,
            anchor: ChatSearchResult.Anchor(
                primary: item.primary,
                archivedId: item.archivedId,
                messageId: item.messageId,
                authorId: item.groupchatAuthorId,
                date: item.date
            )
        )
    }
}

struct ChatSearchTimestampCoverageProof: Equatable, Sendable {
    struct LoadedRange: Equatable, Sendable {
        let oldestArchiveId: String
        let newestArchiveId: String

        func contains(_ archiveId: String) -> Bool {
            let lower = compareArchiveIds(archiveId, oldestArchiveId) ?? .orderedAscending
            let upper = compareArchiveIds(archiveId, newestArchiveId) ?? .orderedDescending
            return lower != .orderedAscending && upper != .orderedDescending
        }
    }

    let loadedRanges: [LoadedRange]
    let olderArchiveEndReached: Bool
    let newerLiveEdgeReached: Bool

    init(
        loadedRanges: [LoadedRange],
        olderArchiveEndReached: Bool,
        newerLiveEdgeReached: Bool
    ) {
        self.loadedRanges = loadedRanges
        self.olderArchiveEndReached = olderArchiveEndReached
        self.newerLiveEdgeReached = newerLiveEdgeReached
    }

    init(_ state: RegularChatArchiveSyncStateStorageItem) {
        loadedRanges = state.loadedRanges.map {
            LoadedRange(
                oldestArchiveId: $0.oldestArchiveId,
                newestArchiveId: $0.newestArchiveId
            )
        }
        olderArchiveEndReached = state.olderArchiveEndReached
        newerLiveEdgeReached = state.newerLiveEdgeReached
    }

    func range(containing anchor: ChatSearchTimestampAnchor) -> LoadedRange? {
        guard anchor.anchor.archivedId.isNotEmpty else { return nil }
        return loadedRanges.first { $0.contains(anchor.anchor.archivedId) }
    }
}

enum ChatSearchTimestampLocalCoveragePolicy {
    static func isSufficient(
        selectedTimestamp: Date,
        nearestBefore: ChatSearchTimestampAnchor?,
        nearestAfter: ChatSearchTimestampAnchor?,
        proof: ChatSearchTimestampCoverageProof
    ) -> Bool {
        if nearestBefore == nil, nearestAfter == nil {
            return proof.olderArchiveEndReached &&
                proof.newerLiveEdgeReached &&
                proof.loadedRanges.count <= 1
        }

        if let nearestAfter,
           nearestAfter.anchor.date == selectedTimestamp {
            return proof.range(containing: nearestAfter) != nil
        }

        if let nearestBefore,
           let nearestAfter,
           let beforeRange = proof.range(containing: nearestBefore),
           let afterRange = proof.range(containing: nearestAfter) {
            return beforeRange == afterRange
        }

        if nearestBefore == nil,
           let nearestAfter,
           let range = proof.range(containing: nearestAfter),
           let oldestRange = proof.loadedRanges.first {
            return proof.olderArchiveEndReached && range == oldestRange
        }

        if nearestAfter == nil,
           let nearestBefore,
           let range = proof.range(containing: nearestBefore),
           let newestRange = proof.loadedRanges.last {
            return proof.newerLiveEdgeReached && range == newestRange
        }

        return false
    }
}

struct ChatSearchTimestampRemoteFallback: Equatable, Sendable {
    let scope: ChatSearchResult.Scope
    let selectedTimestamp: Date
    let localCandidates: [ChatSearchTimestampAnchor]
}

enum ChatSearchTimestampResolutionOutcome: Equatable, Sendable {
    case resolvedLocal(ChatSearchTimestampAnchor)
    case needsRemote(ChatSearchTimestampRemoteFallback)
    case noMessage
    case cancelled
}

struct ChatSearchTimestampResolutionRequest: Equatable, Sendable {
    let id: UUID
    let scope: ChatSearchResult.Scope
    let selectedTimestamp: Date
    let displayedCandidates: [ChatSearchTimestampAnchor]
    let displayedCoverage: ChatSearchTimestampCoverageProof?
}

protocol ChatSearchTimestampResolving: AnyObject {
    func resolve(
        _ request: ChatSearchTimestampResolutionRequest,
        completion: @escaping (ChatSearchTimestampResolutionOutcome) -> Void
    )

    @discardableResult
    func cancel(requestID: UUID) -> Bool
}

final class ChatSearchTimestampResolver: ChatSearchTimestampResolving {
    typealias RealmFactory = (Realm.Configuration) throws -> Realm

    private struct CandidateSelection {
        let nearestBefore: ChatSearchTimestampAnchor?
        let nearestAfter: ChatSearchTimestampAnchor?

        var preferred: ChatSearchTimestampAnchor? {
            nearestAfter ?? nearestBefore
        }

        var boundedRemoteCandidates: [ChatSearchTimestampAnchor] {
            var candidates: [ChatSearchTimestampAnchor] = []
            if let nearestAfter {
                candidates.append(nearestAfter)
            }
            if let nearestBefore,
               !candidates.contains(where: { $0.id == nearestBefore.id }) {
                candidates.append(nearestBefore)
            }
            return Array(candidates.prefix(2))
        }
    }

    private let realmConfiguration: Realm.Configuration
    private let workQueue: DispatchQueue
    private let realmFactory: RealmFactory
    private let stateLock = NSLock()
    private var completions: [UUID: (ChatSearchTimestampResolutionOutcome) -> Void] = [:]

    init(
        realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration,
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.xabber.chat-search.timestamp-resolver",
            qos: .userInitiated
        ),
        realmFactory: @escaping RealmFactory = { configuration in
            try Realm(configuration: configuration)
        }
    ) {
        self.realmConfiguration = realmConfiguration
        self.workQueue = workQueue
        self.realmFactory = realmFactory
    }

    func resolve(
        _ request: ChatSearchTimestampResolutionRequest,
        completion: @escaping (ChatSearchTimestampResolutionOutcome) -> Void
    ) {
        register(completion, for: request.id)
        let displayedSelection = Self.selectCandidates(
            request.displayedCandidates,
            request: request
        )
        let conversationType = ClientSynchronizationManager.ConversationType(
            rawValue: request.scope.conversationTypeRawValue
        )

        if let displayedPreferred = displayedSelection.preferred {
            if conversationType?.isEncrypted == true {
                deliver(.resolvedLocal(displayedPreferred), requestID: request.id)
                return
            }
            if let displayedCoverage = request.displayedCoverage,
               ChatSearchTimestampLocalCoveragePolicy.isSufficient(
                   selectedTimestamp: request.selectedTimestamp,
                   nearestBefore: displayedSelection.nearestBefore,
                   nearestAfter: displayedSelection.nearestAfter,
                   proof: displayedCoverage
               ) {
                deliver(.resolvedLocal(displayedPreferred), requestID: request.id)
                return
            }
        }

        workQueue.async { [weak self] in
            guard let self,
                  self.isActive(request.id) else {
                return
            }
            autoreleasepool {
                do {
                    let realm = try self.realmFactory(self.realmConfiguration)
                    guard self.isActive(request.id) else { return }
                    let selection = self.queryCandidates(in: realm, request: request)
                    let proof = self.queryCoverageProof(in: realm, request: request)
                    let outcome = self.outcome(
                        request: request,
                        conversationType: conversationType,
                        selection: selection,
                        proof: proof
                    )
                    self.deliver(outcome, requestID: request.id)
                } catch {
                    let fallback = ChatSearchTimestampRemoteFallback(
                        scope: request.scope,
                        selectedTimestamp: request.selectedTimestamp,
                        localCandidates: displayedSelection.boundedRemoteCandidates
                    )
                    let outcome: ChatSearchTimestampResolutionOutcome =
                        conversationType?.isEncrypted == true ? .noMessage : .needsRemote(fallback)
                    self.deliver(outcome, requestID: request.id)
                }
            }
        }
    }

    @discardableResult
    func cancel(requestID: UUID) -> Bool {
        guard let completion = takeCompletion(for: requestID) else {
            return false
        }
        DispatchQueue.main.async {
            completion(.cancelled)
        }
        return true
    }

    private func outcome(
        request: ChatSearchTimestampResolutionRequest,
        conversationType: ClientSynchronizationManager.ConversationType?,
        selection: CandidateSelection,
        proof: ChatSearchTimestampCoverageProof?
    ) -> ChatSearchTimestampResolutionOutcome {
        if conversationType?.isEncrypted == true {
            return selection.preferred.map(ChatSearchTimestampResolutionOutcome.resolvedLocal)
                ?? .noMessage
        }

        if let proof,
           ChatSearchTimestampLocalCoveragePolicy.isSufficient(
               selectedTimestamp: request.selectedTimestamp,
               nearestBefore: selection.nearestBefore,
               nearestAfter: selection.nearestAfter,
               proof: proof
           ) {
            return selection.preferred.map(ChatSearchTimestampResolutionOutcome.resolvedLocal)
                ?? .noMessage
        }

        return .needsRemote(
            ChatSearchTimestampRemoteFallback(
                scope: request.scope,
                selectedTimestamp: request.selectedTimestamp,
                localCandidates: selection.boundedRemoteCandidates
            )
        )
    }

    private func queryCandidates(
        in realm: Realm,
        request: ChatSearchTimestampResolutionRequest
    ) -> CandidateSelection {
        let candidates = realm.objects(MessageStorageItem.self).filter(
            "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND isDeleted == false AND isLocallyHiddenByReport == false AND deleteState_ == %@ AND messageType != %@ AND (archivedId != '' OR primary != '')",
            request.scope.owner,
            request.scope.jid,
            request.scope.conversationTypeRawValue,
            MessageStorageItem.DeleteState.visible.rawValue,
            MessageStorageItem.MessageDisplayType.system.rawValue
        )
        let after = candidates
            .filter("date >= %@", request.selectedTimestamp)
            .sorted(byKeyPath: "date", ascending: true)
        let before = candidates
            .filter("date < %@", request.selectedTimestamp)
            .sorted(byKeyPath: "date", ascending: false)

        let nearestAfter = Self.detachBestTie(
            from: after,
            targetDate: after.first?.date,
            scope: request.scope
        )
        let nearestBefore = Self.detachBestTie(
            from: before,
            targetDate: before.first?.date,
            scope: request.scope
        )
        return CandidateSelection(
            nearestBefore: nearestBefore,
            nearestAfter: nearestAfter
        )
    }

    private func queryCoverageProof(
        in realm: Realm,
        request: ChatSearchTimestampResolutionRequest
    ) -> ChatSearchTimestampCoverageProof? {
        guard let conversationType = ClientSynchronizationManager.ConversationType(
            rawValue: request.scope.conversationTypeRawValue
        ), let state = realm.object(
            ofType: RegularChatArchiveSyncStateStorageItem.self,
            forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                jid: request.scope.jid,
                owner: request.scope.owner,
                conversationType: conversationType
            )
        ) else {
            return nil
        }
        return ChatSearchTimestampCoverageProof(state)
    }

    private static func detachBestTie(
        from results: Results<MessageStorageItem>,
        targetDate: Date?,
        scope: ChatSearchResult.Scope
    ) -> ChatSearchTimestampAnchor? {
        guard let targetDate else { return nil }
        return results
            .filter("date == %@", targetDate)
            .compactMap { ChatSearchTimestampAnchor.make(from: $0, scope: scope) }
            .sorted(by: tieSortsBefore)
            .first
    }

    private static func selectCandidates(
        _ candidates: [ChatSearchTimestampAnchor],
        request: ChatSearchTimestampResolutionRequest
    ) -> CandidateSelection {
        let eligible = candidates.filter {
            $0.scope == request.scope &&
                ($0.anchor.archivedId.isNotEmpty || $0.anchor.primary.isNotEmpty)
        }
        let nearestAfter = eligible
            .filter { $0.anchor.date >= request.selectedTimestamp }
            .sorted { lhs, rhs in
                if lhs.anchor.date != rhs.anchor.date {
                    return lhs.anchor.date < rhs.anchor.date
                }
                return tieSortsBefore(lhs, rhs)
            }
            .first
        let nearestBefore = eligible
            .filter { $0.anchor.date < request.selectedTimestamp }
            .sorted { lhs, rhs in
                if lhs.anchor.date != rhs.anchor.date {
                    return lhs.anchor.date > rhs.anchor.date
                }
                return tieSortsBefore(lhs, rhs)
            }
            .first
        return CandidateSelection(
            nearestBefore: nearestBefore,
            nearestAfter: nearestAfter
        )
    }

    private static func tieSortsBefore(
        _ lhs: ChatSearchTimestampAnchor,
        _ rhs: ChatSearchTimestampAnchor
    ) -> Bool {
        switch (lhs.id, rhs.id) {
        case let (.archived(lhsID), .archived(rhsID)):
            let comparison = compareArchiveIds(lhsID, rhsID) ?? .orderedSame
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
            return lhs.anchor.primary < rhs.anchor.primary
        case (.archived, .primary):
            return true
        case (.primary, .archived):
            return false
        case let (.primary(lhsID), .primary(rhsID)):
            return lhsID < rhsID
        }
    }

    private func register(
        _ completion: @escaping (ChatSearchTimestampResolutionOutcome) -> Void,
        for requestID: UUID
    ) {
        stateLock.lock()
        completions[requestID] = completion
        stateLock.unlock()
    }

    private func isActive(_ requestID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return completions[requestID] != nil
    }

    private func takeCompletion(
        for requestID: UUID
    ) -> ((ChatSearchTimestampResolutionOutcome) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return completions.removeValue(forKey: requestID)
    }

    private func deliver(
        _ outcome: ChatSearchTimestampResolutionOutcome,
        requestID: UUID
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let completion = self?.takeCompletion(for: requestID) else {
                return
            }
            completion(outcome)
        }
    }
}
