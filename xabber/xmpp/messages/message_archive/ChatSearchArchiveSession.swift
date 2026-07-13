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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import Foundation

struct ChatSearchArchiveSession: Sendable {
    struct Configuration: Equatable, Sendable {
        let maximumPageCount: Int?
        let maximumResultCount: Int?

        init(
            maximumPageCount: Int? = 1_000,
            maximumResultCount: Int? = nil
        ) {
            self.maximumPageCount = maximumPageCount.map { max(1, $0) }
            self.maximumResultCount = maximumResultCount.map { max(1, $0) }
        }
    }

    struct Result: Equatable, Sendable {
        let id: ChatSearchResult.ID
        let date: Date
    }

    enum FailureReason: Equatable, Sendable {
        case timeout(description: String?)
        case transport(description: String?)
        case requestStart(description: String?)
        case server(description: String?)
        case malformedResponse(description: String?)
    }

    enum TruncationReason: Equatable, Sendable {
        case missingCursor
        case repeatedCursor
        case pageLimitReached(limit: Int)
        case resultLimitReached(limit: Int)
    }

    enum Terminal: Equatable, Sendable {
        case completed(resultCount: Int, pageCount: Int)
        case failed(reason: FailureReason, resultCount: Int, pageCount: Int)
        case cancelled(resultCount: Int, pageCount: Int)
        case truncated(reason: TruncationReason, resultCount: Int, pageCount: Int)
    }

    enum Action: Equatable, Sendable {
        case requestNext(cursor: String)
        case terminal(Terminal)
    }

    private struct PendingFinal: Equatable, Sendable {
        let complete: Bool
        let first: String?
        let last: String?
        let serverResultCount: Int
    }

    let generation: UInt64
    let queryId: String
    let configuration: Configuration

    private(set) var pageCount = 0
    private(set) var totalPersistedMessageCount = 0
    private(set) var terminal: Terminal?

    private var resultsById: [ChatSearchResult.ID: Result] = [:]
    private var requestedCursors: Set<String> = []
    private var pendingFinal: PendingFinal?
    private var didHitResultLimit = false

    init(
        generation: UInt64,
        queryId: String,
        configuration: Configuration = Configuration()
    ) {
        self.generation = generation
        self.queryId = queryId
        self.configuration = configuration
    }

    var isActive: Bool {
        terminal == nil
    }

    var resultCount: Int {
        resultsById.count
    }

    var orderedResults: [Result] {
        resultsById.values.sorted { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date > rhs.date
            }
            return Self.sortKey(for: lhs.id) < Self.sortKey(for: rhs.id)
        }
    }

    mutating func accept(
        result: Result,
        generation: UInt64,
        queryId: String
    ) -> Bool {
        guard matches(generation: generation, queryId: queryId),
              isActive,
              resultsById[result.id] == nil else {
            return false
        }

        if let limit = configuration.maximumResultCount,
           resultsById.count >= limit {
            didHitResultLimit = true
            return false
        }

        resultsById[result.id] = result
        return true
    }

    mutating func receiveFinal(
        generation: UInt64,
        queryId: String,
        complete: Bool,
        first: String?,
        last: String?,
        serverResultCount: Int
    ) -> Bool {
        guard matches(generation: generation, queryId: queryId),
              isActive,
              pendingFinal == nil else {
            return false
        }

        pendingFinal = PendingFinal(
            complete: complete,
            first: Self.normalizedCursor(first),
            last: Self.normalizedCursor(last),
            serverResultCount: max(0, serverResultCount)
        )
        return true
    }

    mutating func commitPersistedPage(
        generation: UInt64,
        queryId: String,
        persistedMessageCount: Int
    ) -> Action? {
        guard matches(generation: generation, queryId: queryId),
              isActive,
              let final = pendingFinal else {
            return nil
        }

        pendingFinal = nil
        pageCount += 1
        totalPersistedMessageCount += max(0, persistedMessageCount)

        if didHitResultLimit,
           let limit = configuration.maximumResultCount {
            return finish(
                .truncated(
                    reason: .resultLimitReached(limit: limit),
                    resultCount: resultCount,
                    pageCount: pageCount
                )
            )
        }

        if final.serverResultCount == 0 && resultCount == 0 {
            return finish(.completed(resultCount: 0, pageCount: pageCount))
        }

        if final.complete {
            return finish(.completed(resultCount: resultCount, pageCount: pageCount))
        }

        if let limit = configuration.maximumPageCount,
           pageCount >= limit {
            return finish(
                .truncated(
                    reason: .pageLimitReached(limit: limit),
                    resultCount: resultCount,
                    pageCount: pageCount
                )
            )
        }

        guard let cursor = final.first else {
            return finish(
                .truncated(
                    reason: .missingCursor,
                    resultCount: resultCount,
                    pageCount: pageCount
                )
            )
        }

        guard requestedCursors.insert(cursor).inserted else {
            return finish(
                .truncated(
                    reason: .repeatedCursor,
                    resultCount: resultCount,
                    pageCount: pageCount
                )
            )
        }

        return .requestNext(cursor: cursor)
    }

    @discardableResult
    mutating func fail(_ reason: FailureReason) -> Terminal {
        if let terminal {
            return terminal
        }
        let terminal = Terminal.failed(
            reason: reason,
            resultCount: resultCount,
            pageCount: pageCount
        )
        self.terminal = terminal
        pendingFinal = nil
        return terminal
    }

    @discardableResult
    mutating func cancel() -> Terminal {
        if let terminal {
            return terminal
        }
        let terminal = Terminal.cancelled(
            resultCount: resultCount,
            pageCount: pageCount
        )
        self.terminal = terminal
        pendingFinal = nil
        return terminal
    }

    private mutating func finish(_ terminal: Terminal) -> Action {
        self.terminal = terminal
        return .terminal(terminal)
    }

    private func matches(generation: UInt64, queryId: String) -> Bool {
        generation == self.generation && queryId == self.queryId
    }

    private static func normalizedCursor(_ cursor: String?) -> String? {
        guard let cursor = cursor?.trimmingCharacters(in: .whitespacesAndNewlines),
              cursor.isNotEmpty else {
            return nil
        }
        return cursor
    }

    private static func sortKey(for id: ChatSearchResult.ID) -> String {
        switch id {
        case .archived(let value):
            return "0:\(value)"
        case .primary(let value):
            return "1:\(value)"
        }
    }
}
