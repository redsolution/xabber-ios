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

protocol ChatSearchProviderCancellation: AnyObject {
    func cancel()
}

protocol ChatSearchProviding: AnyObject {
    @discardableResult
    func start(
        request: ChatSearchSession.Request,
        onEvent: @escaping (ChatSearchSession.ProviderEvent) -> Void
    ) -> ChatSearchProviderCancellation?
}

struct ChatSearchSession: Sendable {
    static let debounceMilliseconds = 300

    struct Scope: Equatable, Sendable {
        let owner: String
        let jid: String
        let conversationTypeRawValue: String
        let isEncrypted: Bool
    }

    enum Provider: Equatable, Sendable {
        case remoteArchive
        case localEncrypted
    }

    struct Request: Equatable, Sendable {
        let generation: UInt64
        let query: String
        let scope: Scope
        let provider: Provider
    }

    enum ProviderPhase: Equatable, Sendable {
        case idle
        case debouncing
        case searching
        case finished
        case failed
    }

    enum ProviderEvent: Equatable, Sendable {
        case result(generation: UInt64, id: ChatSearchResult.ID)
        case finished(generation: UInt64)
        case failed(generation: UInt64)

        var generation: UInt64 {
            switch self {
            case .result(let generation, _),
                 .finished(let generation),
                 .failed(let generation):
                return generation
            }
        }
    }

    enum Effect: Equatable, Sendable {
        case cancelDebounce(generation: UInt64)
        case scheduleDebounce(Request, milliseconds: Int)
        case cancelProviderRequest(generation: UInt64)
        case startProviderRequest(Request)
        case cancelDateResolver
        case cancelPendingNavigation
    }

    private(set) var normalizedQuery: String?
    private(set) var generation: UInt64 = 0
    private(set) var providerPhase: ProviderPhase = .idle
    private(set) var pendingTarget: ChatSearchResult.ID?
    private(set) var committedSelection: ChatSearchResult.ID?
    private(set) var isContextLoading = false

    private var scope: Scope?
    private var scheduledRequest: Request?
    private var activeRequest: Request?
    private var resultIds: Set<ChatSearchResult.ID> = []
    private var isDateResolverActive = false
    private var hasPendingNavigation = false

    var resultCount: Int {
        resultIds.count
    }

    var isProviderSearching: Bool {
        providerPhase == .searching
    }

    var activeScope: Scope? {
        scope
    }

    func isCurrentRequest(_ request: Request) -> Bool {
        request.generation == generation &&
        request.query == normalizedQuery &&
        request.scope == scope &&
        (scheduledRequest == request || activeRequest == request)
    }

    mutating func accept(query: String?, scope: Scope) -> [Effect] {
        let normalized = Self.normalize(query)
        guard normalized.isNotEmpty else {
            guard hasActiveWorkOrQuery else {
                return []
            }
            return cancel()
        }

        let isSameRequest = normalized == normalizedQuery && scope == self.scope
        guard !isSameRequest || providerPhase == .failed else { return [] }

        var effects = cancellationEffects()
        generation &+= 1
        normalizedQuery = normalized
        self.scope = scope
        providerPhase = .debouncing
        pendingTarget = nil
        committedSelection = nil
        isContextLoading = false
        resultIds = []
        isDateResolverActive = false
        hasPendingNavigation = false

        let request = Request(
            generation: generation,
            query: normalized,
            scope: scope,
            provider: scope.isEncrypted ? .localEncrypted : .remoteArchive
        )
        scheduledRequest = request
        activeRequest = nil
        effects.append(
            .scheduleDebounce(request, milliseconds: Self.debounceMilliseconds)
        )
        return effects
    }

    mutating func debounceElapsed(generation: UInt64) -> [Effect] {
        guard let request = scheduledRequest,
              request.generation == generation,
              generation == self.generation else {
            return []
        }
        scheduledRequest = nil
        activeRequest = request
        providerPhase = .searching
        return [.startProviderRequest(request)]
    }

    mutating func flush() -> [Effect] {
        guard let request = scheduledRequest,
              request.generation == generation else {
            return []
        }
        scheduledRequest = nil
        activeRequest = request
        providerPhase = .searching
        return [
            .cancelDebounce(generation: request.generation),
            .startProviderRequest(request)
        ]
    }

    @discardableResult
    mutating func receive(_ event: ProviderEvent) -> Bool {
        guard event.generation == generation,
              activeRequest?.generation == generation else {
            return false
        }

        switch event {
        case .result(_, let id):
            resultIds.insert(id)
            if pendingTarget == nil && committedSelection == nil {
                pendingTarget = id
            }
        case .finished:
            activeRequest = nil
            providerPhase = .finished
        case .failed:
            activeRequest = nil
            providerPhase = .failed
        }
        return true
    }

    @discardableResult
    mutating func replaceResidentResults(
        generation: UInt64,
        ids: [ChatSearchResult.ID]
    ) -> Bool {
        guard generation == self.generation,
              activeRequest?.generation == generation else {
            return false
        }

        resultIds = Set(ids)
        if let pendingTarget,
           !resultIds.contains(pendingTarget) {
            self.pendingTarget = nil
        }
        if let committedSelection,
           !resultIds.contains(committedSelection) {
            self.committedSelection = nil
        }
        if pendingTarget == nil,
           committedSelection == nil {
            pendingTarget = ids.first
        }
        return true
    }

    @discardableResult
    mutating func positioningSucceeded(
        generation: UInt64,
        id: ChatSearchResult.ID
    ) -> Bool {
        guard generation == self.generation,
              pendingTarget == id || resultIds.contains(id) else {
            return false
        }
        pendingTarget = nil
        committedSelection = id
        isContextLoading = false
        hasPendingNavigation = false
        return true
    }

    mutating func setContextLoading(_ isLoading: Bool) {
        isContextLoading = isLoading
    }

    mutating func beginDateResolution() {
        isDateResolverActive = true
    }

    mutating func beginPendingNavigation() {
        hasPendingNavigation = true
    }

    mutating func cancel() -> [Effect] {
        let effects = cancellationEffects()
        if hasActiveWorkOrQuery {
            generation &+= 1
        }
        normalizedQuery = nil
        scope = nil
        scheduledRequest = nil
        activeRequest = nil
        providerPhase = .idle
        pendingTarget = nil
        committedSelection = nil
        isContextLoading = false
        resultIds = []
        isDateResolverActive = false
        hasPendingNavigation = false
        return effects
    }

    mutating func interruptForLifecycle() -> [Effect] {
        let effects = cancellationEffects()
        scheduledRequest = nil
        activeRequest = nil
        isDateResolverActive = false
        hasPendingNavigation = false
        pendingTarget = nil
        isContextLoading = false
        if normalizedQuery == nil {
            providerPhase = .idle
        } else if resultIds.isEmpty {
            providerPhase = .failed
        } else {
            providerPhase = .finished
        }
        return effects
    }

    private var hasActiveWorkOrQuery: Bool {
        normalizedQuery != nil ||
        scheduledRequest != nil ||
        activeRequest != nil ||
        isDateResolverActive ||
        hasPendingNavigation ||
        pendingTarget != nil ||
        committedSelection != nil ||
        resultIds.isNotEmpty
    }

    private func cancellationEffects() -> [Effect] {
        var effects: [Effect] = []
        if let scheduledRequest {
            effects.append(.cancelDebounce(generation: scheduledRequest.generation))
        }
        if let activeRequest {
            effects.append(.cancelProviderRequest(generation: activeRequest.generation))
        }
        if isDateResolverActive {
            effects.append(.cancelDateResolver)
        }
        if hasPendingNavigation {
            effects.append(.cancelPendingNavigation)
        }
        return effects
    }

    private static func normalize(_ query: String?) -> String {
        query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
