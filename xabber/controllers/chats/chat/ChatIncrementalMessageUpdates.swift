//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//

import Foundation

struct ChatIncrementalMessageIdentity: Hashable {
    let primary: String
    let messageId: String?
    let archivedId: String?

    init(primary: String, messageId: String?, archivedId: String?) {
        self.primary = primary
        self.messageId = Self.nonEmpty(messageId)
        self.archivedId = Self.nonEmpty(archivedId)
    }

    init(message: MessageStorageItem) {
        self.init(
            primary: message.primary,
            messageId: message.messageId,
            archivedId: message.archivedId
        )
    }

    var coalescingKey: String {
        if let messageId {
            return "message:\(messageId)"
        }
        if primary.isNotEmpty {
            return "primary:\(primary)"
        }
        if let archivedId {
            return "archive:\(archivedId)"
        }
        return "empty"
    }

    var revisionKeys: [String] {
        var keys: [String] = []
        if primary.isNotEmpty { keys.append("primary:\(primary)") }
        if let messageId { keys.append("message:\(messageId)") }
        if let archivedId { keys.append("archive:\(archivedId)") }
        return keys.isEmpty ? ["empty"] : keys
    }

    func matches(_ other: ChatIncrementalMessageIdentity) -> Bool {
        if primary.isNotEmpty, other.primary.isNotEmpty, primary == other.primary {
            return true
        }
        if let messageId, let otherMessageId = other.messageId, messageId == otherMessageId {
            return true
        }
        if let archivedId, let otherArchivedId = other.archivedId, archivedId == otherArchivedId {
            return true
        }
        return false
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, value.isNotEmpty else { return nil }
        return value
    }
}

enum ChatIncrementalLatestObservationAction: Equatable {
    case upsert
    case delete
    case metadataOnly
}

enum ChatIncrementalLatestObservationPolicy {
    static func action(
        previous: ChatIncrementalMessageIdentity?,
        current: ChatIncrementalMessageIdentity?
    ) -> ChatIncrementalLatestObservationAction {
        switch (previous, current) {
        case (.none, .some):
            return .upsert
        case let (.some(previous), .some(current)):
            return previous == current ? .metadataOnly : .upsert
        case (.some, .none):
            return .delete
        case (.none, .none):
            return .metadataOnly
        }
    }
}

struct ChatIncrementalMessageMutation<Payload> {
    enum Operation {
        case upsert(Payload)
        case delete
    }

    let identity: ChatIncrementalMessageIdentity
    let revision: UInt64
    let operation: Operation

    static func upsert(
        identity: ChatIncrementalMessageIdentity,
        revision: UInt64,
        payload: Payload
    ) -> Self {
        Self(identity: identity, revision: revision, operation: .upsert(payload))
    }

    static func delete(
        identity: ChatIncrementalMessageIdentity,
        revision: UInt64
    ) -> Self {
        Self(identity: identity, revision: revision, operation: .delete)
    }

    var payload: Payload? {
        guard case .upsert(let payload) = operation else { return nil }
        return payload
    }
}

struct ChatIncrementalMessageMutationBatch<Payload> {
    let mutations: [ChatIncrementalMessageMutation<Payload>]
    let enqueuedMutationCount: Int

    var applyCount: Int {
        mutations.isEmpty ? 0 : 1
    }
}

struct ChatIncrementalMessageMutationAccumulator<Payload> {
    private var pendingByKey: [String: ChatIncrementalMessageMutation<Payload>] = [:]
    private var enqueuedMutationCount = 0

    var isEmpty: Bool {
        pendingByKey.isEmpty
    }

    mutating func enqueue(_ mutation: ChatIncrementalMessageMutation<Payload>) {
        enqueuedMutationCount += 1
        let matchingKey = pendingByKey.first {
            $0.value.identity.matches(mutation.identity)
        }?.key
        let key = matchingKey ?? mutation.identity.coalescingKey
        if let pending = pendingByKey[key] {
            if pending.revision > mutation.revision {
                return
            }
            if pending.isServerIdentityUpsertSupersedingAliasDelete(mutation) {
                return
            }
        }
        pendingByKey[key] = mutation
    }

    mutating func enqueue(contentsOf mutations: [ChatIncrementalMessageMutation<Payload>]) {
        mutations.forEach { enqueue($0) }
    }

    mutating func drain() -> ChatIncrementalMessageMutationBatch<Payload> {
        let mutations = pendingByKey.values.sorted {
            if $0.revision != $1.revision {
                return $0.revision < $1.revision
            }
            return $0.identity.coalescingKey < $1.identity.coalescingKey
        }
        let batch = ChatIncrementalMessageMutationBatch(
            mutations: mutations,
            enqueuedMutationCount: enqueuedMutationCount
        )
        pendingByKey.removeAll(keepingCapacity: true)
        enqueuedMutationCount = 0
        return batch
    }
}

private extension ChatIncrementalMessageMutation {
    func isServerIdentityUpsertSupersedingAliasDelete(
        _ candidate: ChatIncrementalMessageMutation<Payload>
    ) -> Bool {
        guard case .upsert = operation,
              case .delete = candidate.operation,
              identity.primary != candidate.identity.primary else {
            return false
        }
        if let messageId = identity.messageId,
           messageId == candidate.identity.messageId {
            return true
        }
        if let archivedId = identity.archivedId,
           archivedId == candidate.identity.archivedId {
            return true
        }
        return false
    }
}

struct ChatIncrementalResidentChangeSet: Equatable {
    static let empty = ChatIncrementalResidentChangeSet(
        insertedPrimaries: [],
        updatedStablePrimaries: [],
        deletedPrimaries: [],
        trimmedPrimaries: [],
        nonResidentIncomingPrimaries: []
    )

    let insertedPrimaries: [String]
    let updatedStablePrimaries: [String]
    let deletedPrimaries: [String]
    let trimmedPrimaries: [String]
    let nonResidentIncomingPrimaries: [String]

    var isEmpty: Bool {
        insertedPrimaries.isEmpty &&
            updatedStablePrimaries.isEmpty &&
            deletedPrimaries.isEmpty &&
            trimmedPrimaries.isEmpty &&
            nonResidentIncomingPrimaries.isEmpty
    }
}

struct ChatIncrementalResidentApplyDiagnostics: Equatable {
    let inputMutationCount: Int
    let appliedMutationCount: Int
    let ignoredStaleMutationCount: Int
    let applyCount: Int
}

struct ChatIncrementalResidentApplyResult {
    let items: [MessageStorageItem]
    let changeSet: ChatIncrementalResidentChangeSet
    let diagnostics: ChatIncrementalResidentApplyDiagnostics
}

struct ChatIncrementalResidentReducer {
    private var newestRevisionByStableKey: [String: UInt64] = [:]

    mutating func apply(
        currentItems: [MessageStorageItem],
        mutations: [ChatIncrementalMessageMutation<MessageStorageItem>],
        isResidentAtLiveTail: Bool,
        hardLimit: Int
    ) -> ChatIncrementalResidentApplyResult {
        var items = currentItems
        var inserted: [String] = []
        var updated: [String] = []
        var deleted: [String] = []
        var nonResidentIncoming: [String] = []
        var ignoredStale = 0
        var applied = 0

        for mutation in mutations {
            let existingIndex = items.firstIndex {
                ChatIncrementalMessageIdentity(message: $0).matches(mutation.identity)
            }
            let existingIdentity = existingIndex.map {
                ChatIncrementalMessageIdentity(message: items[$0])
            }
            var revisionKeys = Set(mutation.identity.revisionKeys)
            existingIdentity?.revisionKeys.forEach { revisionKeys.insert($0) }
            let newestRevision = revisionKeys.compactMap { newestRevisionByStableKey[$0] }.max()
            if let newestRevision, newestRevision > mutation.revision {
                ignoredStale += 1
                continue
            }
            revisionKeys.forEach { newestRevisionByStableKey[$0] = mutation.revision }

            switch mutation.operation {
            case .delete:
                guard let existingIndex else { continue }
                deleted.append(items[existingIndex].primary)
                items.remove(at: existingIndex)
                applied += 1
            case .upsert(let item):
                ChatIncrementalMessageIdentity(message: item).revisionKeys.forEach {
                    newestRevisionByStableKey[$0] = mutation.revision
                }
                if let existingIndex {
                    let stablePrimary = items[existingIndex].primary
                    items[existingIndex] = item
                    updated.append(stablePrimary)
                    applied += 1
                } else if isResidentAtLiveTail {
                    items.append(item)
                    inserted.append(item.primary)
                    applied += 1
                } else if !item.outgoing {
                    nonResidentIncoming.append(item.primary)
                }
            }
        }

        let ordered = ChatTimelineOrdering.deduplicatedChronological(items)
        let limit = max(1, hardLimit)
        let boundedItems = ordered.count > limit ? Array(ordered.suffix(limit)) : ordered
        let boundedPrimaries = Set(boundedItems.map(\.primary))
        let trimmed = ordered
            .map(\.primary)
            .filter { !boundedPrimaries.contains($0) }

        return ChatIncrementalResidentApplyResult(
            items: boundedItems,
            changeSet: ChatIncrementalResidentChangeSet(
                insertedPrimaries: Self.unique(inserted),
                updatedStablePrimaries: Self.unique(updated),
                deletedPrimaries: Self.unique(deleted),
                trimmedPrimaries: Self.unique(trimmed),
                nonResidentIncomingPrimaries: Self.unique(nonResidentIncoming)
            ),
            diagnostics: ChatIncrementalResidentApplyDiagnostics(
                inputMutationCount: mutations.count,
                appliedMutationCount: applied,
                ignoredStaleMutationCount: ignoredStale,
                applyCount: mutations.isEmpty ? 0 : 1
            )
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

struct ChatMessageChangeMask: OptionSet, Equatable {
    let rawValue: UInt8

    static let chrome = ChatMessageChangeMask(rawValue: 1 << 0)
    static let text = ChatMessageChangeMask(rawValue: 1 << 1)
    static let layout = ChatMessageChangeMask(rawValue: 1 << 2)
    static let attachments = ChatMessageChangeMask(rawValue: 1 << 3)
    static let avatar = ChatMessageChangeMask(rawValue: 1 << 4)
    static let all: ChatMessageChangeMask = [.chrome, .text, .layout, .attachments, .avatar]
}

struct ChatMessageCellUpdatePlan: Equatable {
    let changeMask: ChatMessageChangeMask

    var operations: [ChatRenderOperation] {
        var result: [ChatRenderOperation] = []
        if changeMask.contains(.chrome) { result.append(.cellBindChrome) }
        if changeMask.contains(.text) { result.append(.cellBindText) }
        if changeMask.contains(.layout) { result.append(.cellBindLayout) }
        if changeMask.contains(.attachments) { result.append(.cellBindAttachments) }
        if changeMask.contains(.avatar) { result.append(.cellBindAvatar) }
        return result
    }

    var mediaRequestCount: Int {
        changeMask.contains(.attachments) ? 1 : 0
    }

    var rebuildsText: Bool {
        changeMask.contains(.text)
    }

    var invalidatesLayout: Bool {
        changeMask.contains(.layout)
    }

    var rebindsAttachments: Bool {
        changeMask.contains(.attachments)
    }

    var reloadsAvatar: Bool {
        changeMask.contains(.avatar)
    }
}

enum ChatIncrementalViewportDecision: Equatable {
    case none
    case pinBottom
    case preserveViewport(showNewMessageBadge: Bool)
}

enum ChatIncrementalViewportPolicy {
    static func decision(
        insertedItems: [ChatViewController.Datasource],
        wasNearBottom: Bool,
        isResidentAtLiveTail: Bool,
        nonResidentIncomingCount: Int = 0
    ) -> ChatIncrementalViewportDecision {
        if nonResidentIncomingCount > 0 {
            return .preserveViewport(showNewMessageBadge: true)
        }
        guard isResidentAtLiveTail,
              insertedItems.contains(where: { !$0.isFakeMessage && !$0.isOutgoing }) else {
            return .none
        }
        return wasNearBottom
            ? .pinBottom
            : .preserveViewport(showNewMessageBadge: true)
    }
}

enum ChatDatasourceStableIdentity {
    static func diffKey(for item: ChatViewController.Datasource) -> String {
        if item.messageId.isNotEmpty {
            return "message:\(item.owner):\(item.messageId)"
        }
        return "primary:\(item.primary)"
    }

    static func matches(
        _ lhs: ChatViewController.Datasource,
        _ rhs: ChatViewController.Datasource
    ) -> Bool {
        diffKey(for: lhs) == diffKey(for: rhs)
    }
}
