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

import Foundation
import RealmSwift

final class ChatSearchLocalProvider {
    enum Backend: Equatable, Sendable {
        case localRealm
    }

    struct Request: Equatable, Sendable {
        let generation: UInt64
        let queryId: String
        let query: String
        let mappingContext: ChatSearchResultMappingContext
    }

    enum Failure: Equatable, Sendable {
        case unsupportedConversationType(String)
        case realm(String)
    }

    enum Phase: Equatable, Sendable {
        case batch([ChatSearchResult])
        case completed(total: Int)
        case failed(Failure)
        case cancelled
    }

    struct Event: Equatable, Sendable {
        let generation: UInt64
        let queryId: String
        let phase: Phase
    }

    typealias EventHandler = (Event) -> Void
    typealias RealmFactory = (Realm.Configuration) throws -> Realm

    static let backend: Backend = .localRealm

    private struct Identity: Equatable {
        let generation: UInt64
        let queryId: String
    }

    private struct Cursor: Equatable {
        let ordinal: Int64
        let kind: Int
        let high: Int64
        let low: Int64
        let discriminator: Int64
    }

    private struct ActiveRequest {
        let identity: Identity
        let request: Request
        let normalizedQuery: String
        let onEvent: EventHandler
        var nextCursor: Cursor?
        var recentlyDeliveredIDs: Set<ChatSearchResult.ID> = []
        var deliveredResultCount = 0
        var canLoadNextPage = true
        var isLoading = false
    }

    private struct PageLoadContext {
        let identity: Identity
        let request: Request
        let normalizedQuery: String
        let cursor: Cursor?
        let excludedIDs: Set<ChatSearchResult.ID>
    }

    private struct LoadedPage {
        let results: [ChatSearchResult]
        let nextCursor: Cursor?
        let hasMore: Bool
    }

    private let realmConfiguration: Realm.Configuration
    private let batchSize: Int
    private let workQueue: DispatchQueue
    private let realmFactory: RealmFactory
    private let stateLock = NSLock()
    private var activeRequest: ActiveRequest?

    init(
        realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration,
        batchSize: Int = ArchivePageSizing.search,
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.xabber.chat-search.local-provider",
            qos: .userInitiated
        ),
        realmFactory: @escaping RealmFactory = { configuration in
            try Realm(configuration: configuration)
        }
    ) {
        self.realmConfiguration = realmConfiguration
        self.batchSize = max(1, batchSize)
        self.workQueue = workQueue
        self.realmFactory = realmFactory
    }

    func search(
        _ request: Request,
        onEvent: @escaping EventHandler
    ) {
        let identity = Identity(
            generation: request.generation,
            queryId: request.queryId
        )
        let normalizedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let replaced = replaceActiveRequest(
            with: ActiveRequest(
                identity: identity,
                request: request,
                normalizedQuery: normalizedQuery,
                onEvent: onEvent
            )
        ) {
            deliverCancellation(replaced)
        }

        guard ClientSynchronizationManager.ConversationType(
            rawValue: request.mappingContext.scope.conversationTypeRawValue
        ) != nil else {
            emit(
                Event(
                    generation: request.generation,
                    queryId: request.queryId,
                    phase: .failed(
                        .unsupportedConversationType(
                            request.mappingContext.scope.conversationTypeRawValue
                        )
                    )
                ),
                identity: identity,
                terminal: true,
                onEvent: onEvent
            )
            return
        }

        guard normalizedQuery.isNotEmpty else {
            emit(
                Event(
                    generation: request.generation,
                    queryId: request.queryId,
                    phase: .completed(total: 0)
                ),
                identity: identity,
                terminal: true,
                onEvent: onEvent
            )
            return
        }
        _ = requestNextPage(
            queryId: request.queryId,
            generation: request.generation
        )
    }

    @discardableResult
    func cancel(queryId: String, generation: UInt64) -> Bool {
        let identity = Identity(generation: generation, queryId: queryId)
        stateLock.lock()
        guard let activeRequest,
              activeRequest.identity == identity else {
            stateLock.unlock()
            return false
        }
        self.activeRequest = nil
        stateLock.unlock()
        deliverCancellation(activeRequest)
        return true
    }

    func hasPendingPage(queryId: String, generation: UInt64) -> Bool {
        let identity = Identity(generation: generation, queryId: queryId)
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRequest?.identity == identity &&
            activeRequest?.canLoadNextPage == true &&
            activeRequest?.isLoading == false
    }

    func residentBufferedResultCount(queryId: String, generation: UInt64) -> Int {
        let identity = Identity(generation: generation, queryId: queryId)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeRequest?.identity == identity else { return 0 }
        return activeRequest?.recentlyDeliveredIDs.count ?? 0
    }

    @discardableResult
    func requestNextPage(queryId: String, generation: UInt64) -> Bool {
        let identity = Identity(generation: generation, queryId: queryId)
        stateLock.lock()
        guard var activeRequest,
              activeRequest.identity == identity,
              activeRequest.canLoadNextPage,
              !activeRequest.isLoading else {
            stateLock.unlock()
            return false
        }
        activeRequest.isLoading = true
        let context = PageLoadContext(
            identity: identity,
            request: activeRequest.request,
            normalizedQuery: activeRequest.normalizedQuery,
            cursor: activeRequest.nextCursor,
            excludedIDs: activeRequest.recentlyDeliveredIDs
        )
        self.activeRequest = activeRequest
        stateLock.unlock()

        workQueue.async { [weak self] in
            self?.loadPage(context)
        }
        return true
    }

    @discardableResult
    func cancelAll() -> Bool {
        stateLock.lock()
        guard let activeRequest else {
            stateLock.unlock()
            return false
        }
        self.activeRequest = nil
        stateLock.unlock()
        deliverCancellation(activeRequest)
        return true
    }

    private func replaceActiveRequest(with request: ActiveRequest) -> ActiveRequest? {
        stateLock.lock()
        let replaced = activeRequest
        activeRequest = request
        stateLock.unlock()
        return replaced
    }

    private func loadPage(_ context: PageLoadContext) {
        guard isActive(context.identity) else { return }
        autoreleasepool {
            do {
                let realm = try realmFactory(realmConfiguration)
                let loadedPage = makePage(context, realm: realm)
                completePage(loadedPage, context: context)
            } catch {
                guard let onEvent = eventHandler(for: context.identity) else {
                    return
                }
                emit(
                    Event(
                        generation: context.identity.generation,
                        queryId: context.identity.queryId,
                        phase: .failed(.realm(error.localizedDescription))
                    ),
                    identity: context.identity,
                    terminal: true,
                    onEvent: onEvent
                )
            }
        }
    }

    private func makePage(
        _ context: PageLoadContext,
        realm: Realm
    ) -> LoadedPage {
        let scope = context.request.mappingContext.scope
        var storedResults = realm
            .objects(MessageStorageItem.self)
            .filter(
                "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND isDeleted == false AND isLocallyHiddenByReport == false AND messageType != %@ AND body CONTAINS[cd] %@",
                scope.owner,
                scope.jid,
                scope.conversationTypeRawValue,
                MessageStorageItem.MessageDisplayType.system.rawValue,
                context.normalizedQuery
            )
            .sorted(by: [
                SortDescriptor(keyPath: "historyPositionOrdinal", ascending: false),
                SortDescriptor(keyPath: "historyPositionKind", ascending: false),
                SortDescriptor(keyPath: "historyPositionHigh", ascending: false),
                SortDescriptor(keyPath: "historyPositionLow", ascending: false),
                SortDescriptor(keyPath: "historyPositionDiscriminator", ascending: false)
            ])
        if let cursor = context.cursor {
            storedResults = storedResults.filter(
                "historyPositionOrdinal < %@ OR "
                    + "(historyPositionOrdinal == %@ AND historyPositionKind < %@) OR "
                    + "(historyPositionOrdinal == %@ AND historyPositionKind == %@ AND historyPositionHigh < %@) OR "
                    + "(historyPositionOrdinal == %@ AND historyPositionKind == %@ AND historyPositionHigh == %@ AND historyPositionLow < %@) OR "
                    + "(historyPositionOrdinal == %@ AND historyPositionKind == %@ AND historyPositionHigh == %@ AND historyPositionLow == %@ AND historyPositionDiscriminator < %@)",
                cursor.ordinal,
                cursor.ordinal,
                cursor.kind,
                cursor.ordinal,
                cursor.kind,
                cursor.high,
                cursor.ordinal,
                cursor.kind,
                cursor.high,
                cursor.low,
                cursor.ordinal,
                cursor.kind,
                cursor.high,
                cursor.low,
                cursor.discriminator
            )
        }

        var candidates: [(result: ChatSearchResult, cursor: Cursor)] = []
        var indexByID: [ChatSearchResult.ID: Int] = [:]
        candidates.reserveCapacity(batchSize + 1)
        for item in storedResults {
            guard isActive(context.identity) else { break }
            guard let result = ChatSearchResultMapper.map(
                item,
                context: context.request.mappingContext
            ), !context.excludedIDs.contains(result.id) else {
                continue
            }
            let itemCursor = Self.cursor(for: item)
            if let index = indexByID[result.id] {
                candidates[index] = (
                    ChatSearchResultCollection.preferred(candidates[index].result, result),
                    itemCursor
                )
                continue
            }
            indexByID[result.id] = candidates.count
            candidates.append((result, itemCursor))
            if candidates.count > batchSize {
                break
            }
        }

        let hasMore = candidates.count > batchSize
        let included = Array(candidates.prefix(batchSize))
        return LoadedPage(
            results: included.map(\.result),
            nextCursor: hasMore ? included.last?.cursor : nil,
            hasMore: hasMore
        )
    }

    private func completePage(
        _ page: LoadedPage,
        context: PageLoadContext
    ) {
        stateLock.lock()
        guard var activeRequest,
              activeRequest.identity == context.identity else {
            stateLock.unlock()
            return
        }
        activeRequest.isLoading = false
        activeRequest.canLoadNextPage = page.hasMore
        activeRequest.nextCursor = page.nextCursor
        activeRequest.recentlyDeliveredIDs = Set(page.results.map(\.id))
        activeRequest.deliveredResultCount += page.results.count
        let deliveredResultCount = activeRequest.deliveredResultCount
        let onEvent = activeRequest.onEvent
        self.activeRequest = activeRequest
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive(context.identity) else { return }
            if page.results.isNotEmpty {
                onEvent(
                    Event(
                        generation: context.identity.generation,
                        queryId: context.identity.queryId,
                        phase: .batch(page.results)
                    )
                )
            }
            guard !page.hasMore, self.isActive(context.identity) else { return }
            onEvent(
                Event(
                    generation: context.identity.generation,
                    queryId: context.identity.queryId,
                    phase: .completed(total: deliveredResultCount)
                )
            )
            self.finish(context.identity)
        }
    }

    private static func cursor(for item: MessageStorageItem) -> Cursor {
        Cursor(
            ordinal: item.historyPositionOrdinal,
            kind: item.historyPositionKind,
            high: item.historyPositionHigh,
            low: item.historyPositionLow,
            discriminator: item.historyPositionDiscriminator
        )
    }

    private func isActive(_ identity: Identity) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRequest?.identity == identity
    }

    private func eventHandler(for identity: Identity) -> EventHandler? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeRequest?.identity == identity else { return nil }
        return activeRequest?.onEvent
    }

    private func finish(_ identity: Identity) {
        stateLock.lock()
        if activeRequest?.identity == identity {
            activeRequest = nil
        }
        stateLock.unlock()
    }

    private func deliverCancellation(_ request: ActiveRequest) {
        let event = Event(
            generation: request.identity.generation,
            queryId: request.identity.queryId,
            phase: .cancelled
        )
        if Thread.isMainThread {
            request.onEvent(event)
        } else {
            DispatchQueue.main.async {
                request.onEvent(event)
            }
        }
    }

    private func emit(
        _ event: Event,
        identity: Identity,
        terminal: Bool,
        onEvent: @escaping EventHandler
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isActive(identity) else {
                return
            }
            onEvent(event)
            if terminal {
                self.finish(identity)
            }
        }
    }
}
