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

    private let realmConfiguration: Realm.Configuration
    private let batchSize: Int
    private let workQueue: DispatchQueue
    private let realmFactory: RealmFactory
    private let stateLock = NSLock()
    private var activeIdentity: Identity?

    init(
        realmConfiguration: Realm.Configuration = Realm.Configuration.defaultConfiguration,
        batchSize: Int = 64,
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
        replaceActiveIdentity(with: identity)

        guard let conversationType = ClientSynchronizationManager.ConversationType(
            rawValue: request.mappingContext.scope.conversationTypeRawValue
        ), conversationType.isEncrypted else {
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

        let normalizedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
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

        workQueue.async { [weak self] in
            guard let self,
                  self.isActive(identity) else {
                return
            }
            autoreleasepool {
                do {
                    let realm = try self.realmFactory(self.realmConfiguration)
                    let scope = request.mappingContext.scope
                    let storedResults = realm
                        .objects(MessageStorageItem.self)
                        .filter(
                            "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND isDeleted == false AND isLocallyHiddenByReport == false AND messageType != %@ AND body CONTAINS[cd] %@",
                            scope.owner,
                            scope.jid,
                            scope.conversationTypeRawValue,
                            MessageStorageItem.MessageDisplayType.system.rawValue,
                            normalizedQuery
                        )

                    var detachedResults: [ChatSearchResult] = []
                    detachedResults.reserveCapacity(storedResults.count)
                    for item in storedResults {
                        guard self.isActive(identity) else {
                            return
                        }
                        if let result = ChatSearchResultMapper.map(
                            item,
                            context: request.mappingContext
                        ) {
                            detachedResults.append(result)
                        }
                    }

                    let orderedResults = ChatSearchResultCollection.orderedAndDeduplicated(
                        detachedResults
                    )
                    var startIndex = 0
                    while startIndex < orderedResults.count {
                        guard self.isActive(identity) else {
                            return
                        }
                        let endIndex = min(startIndex + self.batchSize, orderedResults.count)
                        self.emit(
                            Event(
                                generation: request.generation,
                                queryId: request.queryId,
                                phase: .batch(Array(orderedResults[startIndex..<endIndex]))
                            ),
                            identity: identity,
                            terminal: false,
                            onEvent: onEvent
                        )
                        startIndex = endIndex
                    }
                    self.emit(
                        Event(
                            generation: request.generation,
                            queryId: request.queryId,
                            phase: .completed(total: orderedResults.count)
                        ),
                        identity: identity,
                        terminal: true,
                        onEvent: onEvent
                    )
                } catch {
                    self.emit(
                        Event(
                            generation: request.generation,
                            queryId: request.queryId,
                            phase: .failed(.realm(error.localizedDescription))
                        ),
                        identity: identity,
                        terminal: true,
                        onEvent: onEvent
                    )
                }
            }
        }
    }

    @discardableResult
    func cancel(queryId: String, generation: UInt64) -> Bool {
        let identity = Identity(generation: generation, queryId: queryId)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeIdentity == identity else {
            return false
        }
        activeIdentity = nil
        return true
    }

    private func replaceActiveIdentity(with identity: Identity) {
        stateLock.lock()
        activeIdentity = identity
        stateLock.unlock()
    }

    private func isActive(_ identity: Identity) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeIdentity == identity
    }

    private func finish(_ identity: Identity) {
        stateLock.lock()
        if activeIdentity == identity {
            activeIdentity = nil
        }
        stateLock.unlock()
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
