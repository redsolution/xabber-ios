import Foundation
import RealmSwift

enum LastChatsSearchProviderID: Hashable, Sendable {
    case localDirectory
    case localMessages
    case encryptedMessages
    case remoteArchive(owner: String, conversationTypeRawValue: String)
}

struct LastChatsSearchConversation: Hashable, Sendable {
    let owner: String
    let jid: String
    let conversationTypeRawValue: String

    var conversationType: ClientSynchronizationManager.ConversationType {
        ClientSynchronizationManager.ConversationType(rawValue: conversationTypeRawValue) ?? .regular
    }

    var stableID: String {
        [owner, jid, conversationTypeRawValue].prp()
    }
}

enum LastChatsSearchResultTargetKind: Hashable, Sendable {
    case latest
    case message
}

enum LastChatsSearchFingerprint {
    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

struct LastChatsSearchResultProvenance: Hashable, Sendable {
    let targetKind: LastChatsSearchResultTargetKind
    let conversation: LastChatsSearchConversation
    let messagePrimary: String?
    let archivedId: String?
    let messageId: String?
    let authorId: String?
    let sourceDate: Date?
    let bodyFingerprint: String?
    let provider: LastChatsSearchProviderID
    let queryGeneration: UInt64

    init(
        targetKind: LastChatsSearchResultTargetKind,
        conversation: LastChatsSearchConversation,
        messagePrimary: String?,
        archivedId: String?,
        messageId: String?,
        authorId: String?,
        sourceDate: Date?,
        bodyFingerprint: String?,
        provider: LastChatsSearchProviderID,
        queryGeneration: UInt64
    ) {
        self.targetKind = targetKind
        self.conversation = conversation
        self.messagePrimary = Self.nonEmpty(messagePrimary)
        self.archivedId = Self.nonEmpty(archivedId)
        self.messageId = Self.nonEmpty(messageId)
        self.authorId = Self.nonEmpty(authorId)
        self.sourceDate = sourceDate
        self.bodyFingerprint = LastChatsSearchFingerprint.normalize(bodyFingerprint)
        self.provider = provider
        self.queryGeneration = queryGeneration
    }

    static func latest(
        conversation: LastChatsSearchConversation,
        provider: LastChatsSearchProviderID,
        queryGeneration: UInt64
    ) -> LastChatsSearchResultProvenance {
        LastChatsSearchResultProvenance(
            targetKind: .latest,
            conversation: conversation,
            messagePrimary: nil,
            archivedId: nil,
            messageId: nil,
            authorId: nil,
            sourceDate: nil,
            bodyFingerprint: nil,
            provider: provider,
            queryGeneration: queryGeneration
        )
    }

    var stableID: String {
        switch targetKind {
        case .latest:
            return "latest:\(conversation.stableID)"
        case .message:
            let identity: String
            if let messagePrimary {
                identity = "primary:\(messagePrimary)"
            } else if let archivedId {
                identity = "archive:\(archivedId)"
            } else if let messageId {
                identity = "message:\([authorId ?? "", messageId].prp())"
            } else if let sourceDate, let bodyFingerprint {
                identity = "fingerprint:\([authorId ?? "", String(sourceDate.timeIntervalSinceReferenceDate), bodyFingerprint].prp())"
            } else {
                identity = "missing:\(provider.stableID):\(queryGeneration)"
            }
            return "message:\([conversation.stableID, identity].prp())"
        }
    }

    var hasMessageIdentity: Bool {
        messagePrimary != nil
            || archivedId != nil
            || messageId != nil
            || (sourceDate != nil && bodyFingerprint != nil)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.isNotEmpty else {
            return nil
        }
        return value
    }
}

private extension LastChatsSearchProviderID {
    var stableID: String {
        switch self {
        case .localDirectory:
            return "local-directory"
        case .localMessages:
            return "local-messages"
        case .encryptedMessages:
            return "encrypted-messages"
        case .remoteArchive(let owner, let conversationTypeRawValue):
            return "remote:\([owner, conversationTypeRawValue].prp())"
        }
    }
}

enum LastChatsSearchRouteUnavailableReason: Equatable, Sendable {
    case staleGeneration
    case missingMessageIdentity
    case targetNotFound
    case ambiguousMessageID
    case ambiguousFingerprintDate
    case fallbackCandidateLimitExceeded
}

struct LastChatsSearchLocalCandidate: Equatable, Sendable {
    let primary: String
    let archivedId: String?
    let messageId: String?
    let authorId: String?
    let sourceDate: Date?
    let bodyFingerprint: String?

    init(
        primary: String,
        archivedId: String?,
        messageId: String?,
        authorId: String?,
        sourceDate: Date?,
        bodyFingerprint: String?
    ) {
        self.primary = primary
        self.archivedId = archivedId
        self.messageId = messageId
        self.authorId = authorId
        self.sourceDate = sourceDate
        self.bodyFingerprint = LastChatsSearchFingerprint.normalize(bodyFingerprint)
    }
}

enum LastChatsSearchLocalResolutionSource: Equatable, Sendable {
    case primary
    case archivedID
    case authorMessageID
    case fingerprintDate
}

enum LastChatsSearchLocalResolution: Equatable, Sendable {
    case matched(LastChatsSearchLocalCandidate, source: LastChatsSearchLocalResolutionSource)
    case unavailable(
        LastChatsSearchRouteUnavailableReason,
        inspectedFallbackCandidateCount: Int
    )
}

enum LastChatsSearchLocalResolver {
    static let defaultFallbackCandidateLimit = 64
    static let dateTolerance: TimeInterval = 1

    static func resolve(
        provenance: LastChatsSearchResultProvenance,
        candidates: [LastChatsSearchLocalCandidate],
        fallbackCandidateLimit: Int = defaultFallbackCandidateLimit
    ) -> LastChatsSearchLocalResolution {
        if let primary = provenance.messagePrimary,
           let candidate = candidates.first(where: { $0.primary == primary }) {
            return .matched(candidate, source: .primary)
        }

        if let archivedId = provenance.archivedId,
           let candidate = candidates.first(where: { $0.archivedId == archivedId }) {
            return .matched(candidate, source: .archivedID)
        }

        if let messageId = provenance.messageId {
            let matches = candidates.filter {
                $0.messageId == messageId
                    && (provenance.authorId == nil || $0.authorId == provenance.authorId)
            }
            if matches.count == 1, let candidate = matches.first {
                return .matched(candidate, source: .authorMessageID)
            }
            if matches.count > 1 {
                return .unavailable(.ambiguousMessageID, inspectedFallbackCandidateCount: 0)
            }
        }

        guard let sourceDate = provenance.sourceDate,
              let fingerprint = provenance.bodyFingerprint else {
            return .unavailable(.targetNotFound, inspectedFallbackCandidateCount: 0)
        }

        let scoped = candidates.filter {
            guard let candidateDate = $0.sourceDate else { return false }
            return abs(candidateDate.timeIntervalSince(sourceDate)) <= dateTolerance
                && (provenance.authorId == nil || $0.authorId == provenance.authorId)
        }
        let limit = max(1, fallbackCandidateLimit)
        if scoped.count > limit {
            return .unavailable(.fallbackCandidateLimitExceeded, inspectedFallbackCandidateCount: limit)
        }

        let matches = scoped.filter { $0.bodyFingerprint == fingerprint }
        if matches.count == 1, let candidate = matches.first {
            return .matched(candidate, source: .fingerprintDate)
        }
        if matches.count > 1 {
            return .unavailable(
                .ambiguousFingerprintDate,
                inspectedFallbackCandidateCount: scoped.count
            )
        }
        return .unavailable(.targetNotFound, inspectedFallbackCandidateCount: scoped.count)
    }
}

struct LastChatsSearchCursor: Hashable, Sendable {
    let opaque: String
}

struct LastChatsSearchLocalCursorPosition: Equatable, Sendable, Codable {
    let ordinal: Int64
    let kind: Int
    let high: Int64
    let low: Int64
    let discriminator: Int64
}

struct LastChatsSearchPageRequest: Hashable, Sendable {
    let generation: UInt64
    let provider: LastChatsSearchProviderID
    let query: String
    let cursor: LastChatsSearchCursor?
    let ordinal: Int
    let limit: Int
}

struct LastChatsSearchItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case conversation
        case roster
        case message
    }

    let stableID: String
    let kind: Kind
    let owner: String
    let jid: String
    let conversationTypeRawValue: String
    let storagePrimary: String
    let date: Date
    let revision: UInt64
    let localCursorPosition: LastChatsSearchLocalCursorPosition?
    let provenance: LastChatsSearchResultProvenance?

    init(
        stableID: String,
        kind: Kind,
        owner: String,
        jid: String,
        conversationTypeRawValue: String,
        storagePrimary: String,
        date: Date,
        revision: UInt64,
        localCursorPosition: LastChatsSearchLocalCursorPosition? = nil,
        provenance: LastChatsSearchResultProvenance? = nil
    ) {
        self.stableID = stableID
        self.kind = kind
        self.owner = owner
        self.jid = jid
        self.conversationTypeRawValue = conversationTypeRawValue
        self.storagePrimary = storagePrimary
        self.date = date
        self.revision = revision
        self.localCursorPosition = localCursorPosition
        self.provenance = provenance
    }
}

struct LastChatsSearchProviderPage: Equatable, Sendable {
    let request: LastChatsSearchPageRequest
    let items: [LastChatsSearchItem]
    let nextCursor: LastChatsSearchCursor?
}

enum LastChatsSearchProviderFailure: Equatable, Sendable {
    case providerUnavailable
    case queryFailed
    case cancelled
}

enum LastChatsSearchProviderEvent: Equatable, Sendable {
    case page(LastChatsSearchProviderPage)
    case finished(LastChatsSearchPageRequest)
    case failed(LastChatsSearchPageRequest, reason: LastChatsSearchProviderFailure)

    var request: LastChatsSearchPageRequest {
        switch self {
        case .page(let page):
            return page.request
        case .finished(let request), .failed(let request, _):
            return request
        }
    }
}

struct LastChatsSearchPipeline {
    struct Configuration: Equatable, Sendable {
        let pageSize: Int
        let maximumResidentPagesPerProvider: Int
        let maximumResidentItems: Int

        init(
            pageSize: Int = 50,
            maximumResidentPagesPerProvider: Int = 3,
            maximumResidentItems: Int = 400
        ) {
            self.pageSize = max(1, pageSize)
            self.maximumResidentPagesPerProvider = max(1, maximumResidentPagesPerProvider)
            self.maximumResidentItems = max(1, maximumResidentItems)
        }
    }

    struct Counters: Equatable, Sendable {
        fileprivate(set) var acceptedPageCount = 0
        fileprivate(set) var rejectedEventCount = 0
        fileprivate(set) var coalescedRequestCount = 0
        fileprivate(set) var orderComparisonCount = 0
        fileprivate(set) var trimmedItemCount = 0
        let fullSortCount = 0
    }

    enum ProviderTerminal: Equatable, Sendable {
        case finished
        case failed(LastChatsSearchProviderFailure)
    }

    struct Snapshot: Equatable, Sendable {
        fileprivate let providerCount: Int
        fileprivate let residentPagesByProvider: [LastChatsSearchProviderID: Int]
        let generation: UInt64
        let query: String?
        let items: [LastChatsSearchItem]
        let terminalByProvider: [LastChatsSearchProviderID: ProviderTerminal]
        let isCancelled: Bool
        let counters: Counters

        var isLoading: Bool {
            query != nil && terminalByProvider.count < providerCount
        }

        func residentPageCount(for provider: LastChatsSearchProviderID) -> Int {
            residentPagesByProvider[provider] ?? 0
        }
    }

    private struct PageOwner: Hashable {
        let provider: LastChatsSearchProviderID
        let ordinal: Int
    }

    private struct ProviderState {
        var inflight: LastChatsSearchPageRequest?
        var lastAccepted: LastChatsSearchPageRequest?
        var nextCursor: LastChatsSearchCursor?
        var pages: [PageOwner] = []
        var terminal: ProviderTerminal?
    }

    let configuration: Configuration

    private(set) var generation: UInt64 = 0
    private var query: String?
    private var providerOrder: [LastChatsSearchProviderID] = []
    private var providerStates: [LastChatsSearchProviderID: ProviderState] = [:]
    private var itemsByID: [String: LastChatsSearchItem] = [:]
    private var orderedIDs: [String] = []
    private var itemOwners: [String: Set<PageOwner>] = [:]
    private var pageItemIDs: [PageOwner: Set<String>] = [:]
    private var counters = Counters()
    private var isCancelled = false

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var snapshot: Snapshot {
        Snapshot(
            providerCount: providerOrder.count,
            residentPagesByProvider: Dictionary(
                uniqueKeysWithValues: providerOrder.map { provider in
                    (provider, providerStates[provider]?.pages.count ?? 0)
                }
            ),
            generation: generation,
            query: query,
            items: orderedIDs.compactMap { itemsByID[$0] },
            terminalByProvider: Dictionary(
                uniqueKeysWithValues: providerOrder.compactMap { provider in
                    guard let terminal = providerStates[provider]?.terminal else {
                        return nil
                    }
                    return (provider, terminal)
                }
            ),
            isCancelled: isCancelled,
            counters: counters
        )
    }

    mutating func begin(
        query rawQuery: String,
        providers rawProviders: [LastChatsSearchProviderID]
    ) -> [LastChatsSearchPageRequest] {
        let normalized = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isNotEmpty else {
            cancel()
            return []
        }

        generation &+= 1
        query = normalized
        providerOrder = unique(rawProviders)
        providerStates.removeAll(keepingCapacity: true)
        itemsByID.removeAll(keepingCapacity: true)
        orderedIDs.removeAll(keepingCapacity: true)
        itemOwners.removeAll(keepingCapacity: true)
        pageItemIDs.removeAll(keepingCapacity: true)
        counters = Counters()
        isCancelled = false

        return providerOrder.map { provider in
            let request = LastChatsSearchPageRequest(
                generation: generation,
                provider: provider,
                query: normalized,
                cursor: nil,
                ordinal: 0,
                limit: configuration.pageSize
            )
            providerStates[provider] = ProviderState(inflight: request)
            return request
        }
    }

    mutating func requestNextPage(
        for provider: LastChatsSearchProviderID
    ) -> LastChatsSearchPageRequest? {
        guard !isCancelled,
              let query,
              var state = providerStates[provider],
              state.terminal == nil,
              let cursor = state.nextCursor else {
            return nil
        }
        guard state.inflight == nil else {
            counters.coalescedRequestCount += 1
            return nil
        }

        let request = LastChatsSearchPageRequest(
            generation: generation,
            provider: provider,
            query: query,
            cursor: cursor,
            ordinal: (state.lastAccepted?.ordinal ?? -1) + 1,
            limit: configuration.pageSize
        )
        state.inflight = request
        providerStates[provider] = state
        return request
    }

    @discardableResult
    mutating func receive(_ event: LastChatsSearchProviderEvent) -> Bool {
        let request = event.request
        guard !isCancelled,
              request.generation == generation,
              request.query == query,
              var state = providerStates[request.provider],
              state.inflight == request || state.lastAccepted == request else {
            counters.rejectedEventCount += 1
            return false
        }

        switch event {
        case .page(let page):
            guard state.inflight == request else {
                counters.rejectedEventCount += 1
                return false
            }
            state.inflight = nil
            state.lastAccepted = request
            state.nextCursor = page.nextCursor
            let owner = PageOwner(provider: request.provider, ordinal: request.ordinal)
            merge(page.items, owner: owner)
            state.pages.append(owner)
            trimProviderPages(&state)
            providerStates[request.provider] = state
            trimGlobalItemsIfNeeded()
            counters.acceptedPageCount += 1
        case .finished:
            state.inflight = nil
            state.nextCursor = nil
            state.terminal = .finished
            providerStates[request.provider] = state
        case .failed(_, let reason):
            state.inflight = nil
            state.nextCursor = nil
            state.terminal = .failed(reason)
            providerStates[request.provider] = state
        }
        return true
    }

    mutating func cancel() {
        if query != nil || !providerStates.isEmpty || !isCancelled {
            generation &+= 1
        }
        query = nil
        providerOrder.removeAll(keepingCapacity: false)
        providerStates.removeAll(keepingCapacity: false)
        itemsByID.removeAll(keepingCapacity: false)
        orderedIDs.removeAll(keepingCapacity: false)
        itemOwners.removeAll(keepingCapacity: false)
        pageItemIDs.removeAll(keepingCapacity: false)
        isCancelled = true
    }

    private mutating func merge(_ incoming: [LastChatsSearchItem], owner: PageOwner) {
        var ownedIDs = pageItemIDs[owner] ?? []
        for item in incoming {
            ownedIDs.insert(item.stableID)
            itemOwners[item.stableID, default: []].insert(owner)
            if let current = itemsByID[item.stableID] {
                guard preferred(item, over: current) else { continue }
                removeOrderedID(item.stableID)
            }
            itemsByID[item.stableID] = item
            insertOrdered(item)
        }
        pageItemIDs[owner] = ownedIDs
    }

    private mutating func trimProviderPages(_ state: inout ProviderState) {
        while state.pages.count > configuration.maximumResidentPagesPerProvider {
            removePage(state.pages.removeFirst())
        }
    }

    private mutating func removePage(_ owner: PageOwner) {
        let ids = pageItemIDs.removeValue(forKey: owner) ?? []
        for id in ids {
            itemOwners[id]?.remove(owner)
            if itemOwners[id]?.isEmpty == true {
                itemOwners.removeValue(forKey: id)
                itemsByID.removeValue(forKey: id)
                removeOrderedID(id)
                counters.trimmedItemCount += 1
            }
        }
    }

    private mutating func trimGlobalItemsIfNeeded() {
        while orderedIDs.count > configuration.maximumResidentItems,
              let id = orderedIDs.last {
            orderedIDs.removeLast()
            itemsByID.removeValue(forKey: id)
            itemOwners.removeValue(forKey: id)
            counters.trimmedItemCount += 1
        }
    }

    private mutating func insertOrdered(_ item: LastChatsSearchItem) {
        var lower = 0
        var upper = orderedIDs.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            guard let candidate = itemsByID[orderedIDs[middle]] else {
                lower = middle + 1
                continue
            }
            counters.orderComparisonCount += 1
            if sortsBefore(item, candidate) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        orderedIDs.insert(item.stableID, at: lower)
    }

    private mutating func removeOrderedID(_ id: String) {
        guard let index = orderedIDs.firstIndex(of: id) else { return }
        orderedIDs.remove(at: index)
    }

    private func sortsBefore(_ lhs: LastChatsSearchItem, _ rhs: LastChatsSearchItem) -> Bool {
        if lhs.date != rhs.date {
            return lhs.date > rhs.date
        }
        return lhs.stableID > rhs.stableID
    }

    private func preferred(_ candidate: LastChatsSearchItem, over current: LastChatsSearchItem) -> Bool {
        if candidate.revision != current.revision {
            return candidate.revision > current.revision
        }
        if candidate.date != current.date {
            return candidate.date > current.date
        }
        return candidate.storagePrimary > current.storagePrimary
    }

    private func unique(_ providers: [LastChatsSearchProviderID]) -> [LastChatsSearchProviderID] {
        var seen: Set<LastChatsSearchProviderID> = []
        return providers.filter { seen.insert($0).inserted }
    }
}

enum LastChatsSearchProviderPlan {
    static func make(enabledOwners: [String]) -> [LastChatsSearchProviderID] {
        var providers: [LastChatsSearchProviderID] = [
            .localDirectory,
            .localMessages,
            .encryptedMessages
        ]
        for owner in enabledOwners {
            providers.append(
                .remoteArchive(
                    owner: owner,
                    conversationTypeRawValue: ClientSynchronizationManager.ConversationType.regular.rawValue
                )
            )
            providers.append(
                .remoteArchive(
                    owner: owner,
                    conversationTypeRawValue: ClientSynchronizationManager.ConversationType.group.rawValue
                )
            )
        }
        return providers
    }
}

protocol LastChatsSearchLogicalSourceCountProviding {
    var logicalSourceCount: Int { get }
}

enum LastChatsSearchPageMaterializer {
    struct Metrics: Equatable, Sendable {
        let logicalSourceCount: Int
        let materializedCount: Int
    }

    struct Page<Item>: Sendable where Item: Sendable {
        let items: [Item]
        let hasMore: Bool
        let metrics: Metrics
    }

    static func materialize<Matches, Item>(
        _ matches: Matches,
        limit: Int,
        transform: (Matches.Element) -> Item
    ) -> Page<Item>
    where Matches: RandomAccessCollection, Item: Sendable {
        let boundedLimit = max(1, limit)
        let materializationLimit = boundedLimit + 1
        var index = matches.startIndex
        var output: [Item] = []
        output.reserveCapacity(materializationLimit)

        while index != matches.endIndex && output.count < materializationLimit {
            output.append(transform(matches[index]))
            matches.formIndex(after: &index)
        }

        let materializedCount = output.count
        let hasMore = materializedCount > boundedLimit
        if hasMore {
            output.removeLast()
        }
        let logicalSourceCount = (matches as? LastChatsSearchLogicalSourceCountProviding)?.logicalSourceCount
            ?? matches.count
        return Page(
            items: output,
            hasMore: hasMore,
            metrics: Metrics(
                logicalSourceCount: logicalSourceCount,
                materializedCount: materializedCount
            )
        )
    }
}

final class LastChatsSearchCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class LastChatsSearchBackgroundPageExecutor: @unchecked Sendable {
    typealias Loader = @Sendable (LastChatsSearchPageRequest) -> LastChatsSearchProviderPage

    private let queue: DispatchQueue
    private let loader: Loader

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "com.xabber.last-chats-search.pages",
            qos: .userInitiated
        ),
        loader: @escaping Loader
    ) {
        self.queue = queue
        self.loader = loader
    }

    @discardableResult
    func load(
        request: LastChatsSearchPageRequest,
        completion: @escaping @Sendable (LastChatsSearchProviderPage) -> Void
    ) -> LastChatsSearchCancellationToken {
        let cancellation = LastChatsSearchCancellationToken()
        queue.async { [loader] in
            guard !cancellation.isCancelled else { return }
            let page = loader(request)
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async {
                guard !cancellation.isCancelled else { return }
                completion(page)
            }
        }
        return cancellation
    }
}

struct LastChatsSearchLocalPageLoader: @unchecked Sendable {
    private enum DirectoryPhase: String, Codable {
        case conversations
        case roster
    }

    private struct CursorPayload: Codable {
        let phase: DirectoryPhase?
        let offset: Int?
        let position: LastChatsSearchLocalCursorPosition?
    }

    private static let encryptedConversationTypes = [
        ClientSynchronizationManager.ConversationType.omemo.rawValue,
        ClientSynchronizationManager.ConversationType.omemo1.rawValue,
        ClientSynchronizationManager.ConversationType.axolotl.rawValue
    ]

    let enabledOwners: [String]

    func load(_ request: LastChatsSearchPageRequest) -> LastChatsSearchProviderPage {
        guard enabledOwners.isNotEmpty else {
            return LastChatsSearchProviderPage(request: request, items: [], nextCursor: nil)
        }

        do {
            let realm = try WRealm.safe()
            switch request.provider {
            case .localDirectory:
                return directoryPage(request, realm: realm)
            case .localMessages:
                return messagePage(request, realm: realm, encrypted: false)
            case .encryptedMessages:
                return messagePage(request, realm: realm, encrypted: true)
            case .remoteArchive:
                return LastChatsSearchProviderPage(request: request, items: [], nextCursor: nil)
            }
        } catch {
            return LastChatsSearchProviderPage(request: request, items: [], nextCursor: nil)
        }
    }

    private func directoryPage(
        _ request: LastChatsSearchPageRequest,
        realm: Realm
    ) -> LastChatsSearchProviderPage {
        let cursor = decode(request.cursor)
        let phase = cursor?.phase ?? .conversations
        var items: [LastChatsSearchItem] = []
        items.reserveCapacity(request.limit)

        if phase == .conversations {
            let conversations = realm
                .objects(LastChatsStorageItem.self)
                .filter(
                    "owner IN %@ AND (jid CONTAINS[cd] %@ OR rosterItem.customUsername CONTAINS[cd] %@ OR rosterItem.username CONTAINS[cd] %@)",
                    enabledOwners,
                    request.query,
                    request.query,
                    request.query
                )
                .sorted(by: [
                    SortDescriptor(keyPath: "messageDate", ascending: false),
                    SortDescriptor(keyPath: "primary", ascending: false)
                ])
            let conversationOffset = max(0, cursor?.offset ?? 0)

            let page = LastChatsSearchPageMaterializer.materialize(
                conversations.dropFirst(conversationOffset),
                limit: request.limit,
                transform: { Self.conversationProjection($0, request: request) }
            )
            items.append(contentsOf: page.items)
            if page.hasMore {
                return LastChatsSearchProviderPage(
                    request: request,
                    items: items,
                    nextCursor: encode(
                        CursorPayload(
                            phase: .conversations,
                            offset: conversationOffset + page.items.count,
                            position: nil
                        )
                    )
                )
            }
            if items.count == request.limit {
                return LastChatsSearchProviderPage(
                    request: request,
                    items: items,
                    nextCursor: encode(CursorPayload(phase: .roster, offset: 0, position: nil))
                )
            }
        }

        let remaining = max(1, request.limit - items.count)
        let roster = realm
            .objects(RosterStorageItem.self)
            .filter(
                "owner IN %@ AND removed == false AND isHidden == false AND (jid CONTAINS[cd] %@ OR customUsername CONTAINS[cd] %@ OR username CONTAINS[cd] %@)",
                enabledOwners,
                request.query,
                request.query,
                request.query
            )
            .sorted(byKeyPath: "primary", ascending: false)
        let rosterOffset = phase == .roster ? max(0, cursor?.offset ?? 0) : 0

        let rosterPage = LastChatsSearchPageMaterializer.materialize(
            roster.dropFirst(rosterOffset),
            limit: remaining,
            transform: { Self.rosterProjection($0, request: request) }
        )
        items.append(contentsOf: rosterPage.items)
        let nextCursor: LastChatsSearchCursor?
        if rosterPage.hasMore {
            nextCursor = encode(
                CursorPayload(
                    phase: .roster,
                    offset: rosterOffset + rosterPage.items.count,
                    position: nil
                )
            )
        } else {
            nextCursor = nil
        }
        return LastChatsSearchProviderPage(
            request: request,
            items: items,
            nextCursor: nextCursor
        )
    }

    private func messagePage(
        _ request: LastChatsSearchPageRequest,
        realm: Realm,
        encrypted: Bool
    ) -> LastChatsSearchProviderPage {
        let conversationPredicate = encrypted
            ? "conversationType_ IN %@"
            : "NOT (conversationType_ IN %@)"
        var messages = realm
            .objects(MessageStorageItem.self)
            .filter(
                "owner IN %@ AND isDeleted == false AND messageType != %@ AND body CONTAINS[cd] %@ AND \(conversationPredicate)",
                enabledOwners,
                MessageStorageItem.MessageDisplayType.system.rawValue,
                request.query,
                Self.encryptedConversationTypes
            )
            .sorted(by: [
                SortDescriptor(keyPath: "historyPositionOrdinal", ascending: false),
                SortDescriptor(keyPath: "historyPositionKind", ascending: false),
                SortDescriptor(keyPath: "historyPositionHigh", ascending: false),
                SortDescriptor(keyPath: "historyPositionLow", ascending: false),
                SortDescriptor(keyPath: "historyPositionDiscriminator", ascending: false)
            ])
        if let position = decode(request.cursor)?.position {
            messages = messages.filter(
                "historyPositionOrdinal < %@ OR "
                    + "(historyPositionOrdinal == %@ AND historyPositionKind < %@) OR "
                    + "(historyPositionOrdinal == %@ AND historyPositionKind == %@ AND historyPositionHigh < %@) OR "
                    + "(historyPositionOrdinal == %@ AND historyPositionKind == %@ AND historyPositionHigh == %@ AND historyPositionLow < %@) OR "
                    + "(historyPositionOrdinal == %@ AND historyPositionKind == %@ AND historyPositionHigh == %@ AND historyPositionLow == %@ AND historyPositionDiscriminator < %@)",
                position.ordinal,
                position.ordinal,
                position.kind,
                position.ordinal,
                position.kind,
                position.high,
                position.ordinal,
                position.kind,
                position.high,
                position.low,
                position.ordinal,
                position.kind,
                position.high,
                position.low,
                position.discriminator
            )
        }

        let page = LastChatsSearchPageMaterializer.materialize(
            messages,
            limit: request.limit,
            transform: { Self.messageProjection($0, request: request) }
        )
        let nextCursor: LastChatsSearchCursor?
        if page.hasMore, let position = page.items.last?.localCursorPosition {
            nextCursor = encode(
                CursorPayload(
                    phase: nil,
                    offset: nil,
                    position: position
                )
            )
        } else {
            nextCursor = nil
        }
        return LastChatsSearchProviderPage(
            request: request,
            items: page.items,
            nextCursor: nextCursor
        )
    }

    private static func conversationProjection(
        _ item: LastChatsStorageItem,
        request: LastChatsSearchPageRequest
    ) -> LastChatsSearchItem {
        let conversation = LastChatsSearchConversation(
            owner: item.owner,
            jid: item.jid,
            conversationTypeRawValue: item.conversationType_
        )
        return LastChatsSearchItem(
            stableID: conversationStableID(
                owner: item.owner,
                jid: item.jid,
                conversationTypeRawValue: item.conversationType_
            ),
            kind: .conversation,
            owner: item.owner,
            jid: item.jid,
            conversationTypeRawValue: item.conversationType_,
            storagePrimary: item.primary,
            date: item.messageDate,
            revision: revision(timestamp: max(item.messageDate.timeIntervalSince1970, item.updateTS)),
            provenance: .latest(
                conversation: conversation,
                provider: request.provider,
                queryGeneration: request.generation
            )
        )
    }

    private static func rosterProjection(
        _ item: RosterStorageItem,
        request: LastChatsSearchPageRequest
    ) -> LastChatsSearchItem {
        let conversationType = item.isContact
            ? ClientSynchronizationManager.ConversationType(
                rawValue: CommonConfigManager.shared.config.locked_conversation_type
            ) ?? .regular
            : .group
        return LastChatsSearchItem(
            stableID: conversationStableID(
                owner: item.owner,
                jid: item.jid,
                conversationTypeRawValue: conversationType.rawValue
            ),
            kind: .roster,
            owner: item.owner,
            jid: item.jid,
            conversationTypeRawValue: conversationType.rawValue,
            storagePrimary: item.primary,
            date: Date(timeIntervalSince1970: 0),
            revision: revision(timestamp: item.updatedTS),
            provenance: .latest(
                conversation: LastChatsSearchConversation(
                    owner: item.owner,
                    jid: item.jid,
                    conversationTypeRawValue: conversationType.rawValue
                ),
                provider: request.provider,
                queryGeneration: request.generation
            )
        )
    }

    static func messageProjection(
        _ item: MessageStorageItem,
        request: LastChatsSearchPageRequest? = nil
    ) -> LastChatsSearchItem {
        let editTimestamp = item.editDate?.timeIntervalSince1970 ?? 0
        let provenance = request.map {
            LastChatsSearchResultProvenance(
                targetKind: .message,
                conversation: LastChatsSearchConversation(
                    owner: item.owner,
                    jid: item.opponent,
                    conversationTypeRawValue: item.conversationType_
                ),
                messagePrimary: item.primary,
                archivedId: item.archivedId,
                messageId: item.messageId,
                authorId: item.groupchatAuthorId,
                sourceDate: item.date,
                bodyFingerprint: item.displayedBody(),
                provider: $0.provider,
                queryGeneration: $0.generation
            )
        }
        return LastChatsSearchItem(
            stableID: "message:\(item.primary)",
            kind: .message,
            owner: item.owner,
            jid: item.opponent,
            conversationTypeRawValue: item.conversationType_,
            storagePrimary: item.primary,
            date: item.date,
            revision: revision(timestamp: max(item.date.timeIntervalSince1970, editTimestamp)),
            localCursorPosition: LastChatsSearchLocalCursorPosition(
                ordinal: item.historyPositionOrdinal,
                kind: item.historyPositionKind,
                high: item.historyPositionHigh,
                low: item.historyPositionLow,
                discriminator: item.historyPositionDiscriminator
            ),
            provenance: provenance
        )
    }

    private static func conversationStableID(
        owner: String,
        jid: String,
        conversationTypeRawValue: String
    ) -> String {
        "conversation:\([owner, jid, conversationTypeRawValue].prp())"
    }

    private static func revision(timestamp: TimeInterval) -> UInt64 {
        UInt64(max(0, timestamp * 1_000))
    }

    private func decode(_ cursor: LastChatsSearchCursor?) -> CursorPayload? {
        guard let cursor,
              let data = Data(base64Encoded: cursor.opaque) else {
            return nil
        }
        return try? JSONDecoder().decode(CursorPayload.self, from: data)
    }

    private func encode(_ payload: CursorPayload) -> LastChatsSearchCursor? {
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return LastChatsSearchCursor(opaque: data.base64EncodedString())
    }
}
