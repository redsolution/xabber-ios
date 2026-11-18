import CryptoKit
import Foundation
import XMPPFramework

enum ScheduledMessageAction: Codable, Equatable {
    case delete
    case edit(String)
    case editContent(body: String, retainedAttachmentIDs: [Int], addedAttachmentXML: [String])
    case reschedule(Date)
    case sendNow
}

struct ScheduledMessageActionRecovery: Equatable {
    let item: ScheduledMessageListItem
    let action: ScheduledMessageAction
    let requiresRefresh: Bool
}

struct ScheduledMessageActionFailure: Error {
    let error: XMPPMessageScheduleManager.ScheduleError
    let recovery: ScheduledMessageActionRecovery?
}

@MainActor
final class ScheduledMessageActionCoordinator {
    typealias ScheduleError = XMPPMessageScheduleManager.ScheduleError
    typealias ActionResult = Result<Void, ScheduledMessageActionFailure>

    private struct Identity: Hashable {
        let owner: String
        let scheduledId: String

        init(_ item: ScheduledMessageListItem) {
            owner = item.owner
            scheduledId = item.scheduledId
        }
    }

    private static var inFlight: Set<Identity> = []
    private let service: ChatScheduledMessageServicing
    private let now: () -> Date
    private let journal: ScheduledMessageActionJournal

    init(
        service: ChatScheduledMessageServicing,
        now: @escaping () -> Date = Date.init,
        journal: ScheduledMessageActionJournal = .shared
    ) {
        self.service = service
        self.now = now
        self.journal = journal
    }

    nonisolated static func supports(_ action: ScheduledMessageAction, on item: ScheduledMessageListItem) -> Bool {
        guard ScheduledMessageActionPayload.hasValidIdentity(item) else { return false }
        if action == .delete { return true }
        return ScheduledMessageActionPayload.make(action, item: item) != nil
    }

    func perform(_ action: ScheduledMessageAction, on item: ScheduledMessageListItem) async -> ActionResult {
        let identity = Identity(item)
        guard Self.inFlight.insert(identity).inserted else { return failure(.sendRejected) }
        defer { Self.inFlight.remove(identity) }

        if let recovery = journal.record(for: item) {
            return failure(.sendRejected, recovery: recovery)
        }
        if let error = preflight(action, item: item) { return failure(error) }
        let payload = ScheduledMessageActionPayload.make(action, item: item)
        if action != .delete {
            guard payload != nil, journal.begin(item: item, action: action) else {
                return failure(.sendRejected)
            }
        }
        let cancelled: Result<String, ScheduleError> = await request { callback in
            service.cancelScheduledMessage(owner: item.owner, scheduledId: item.scheduledId, callback: callback)
        }
        switch cancelled {
        case .success(let cancelledId) where cancelledId == item.scheduledId:
            guard let payload else { return .success(()) }
            return await submit(payload, action: action, item: item)
        case .success:
            await refresh(item)
            return failure(.invalidResponse, recovery: journal.record(for: item))
        case .failure(let error):
            if !hasUnknownOutcome(error), action != .delete {
                journal.remove(item: item)
            }
            if error == .itemNotFound || hasUnknownOutcome(error) {
                await refresh(item)
            }
            return failure(error, recovery: journal.record(for: item))
        }
    }

    func perform(
        _ action: ScheduledMessageAction,
        on items: [ScheduledMessageListItem]
    ) async -> [(item: ScheduledMessageListItem, result: ActionResult)] {
        var visited = Set<Identity>()
        let sorted = items.sorted {
            if $0.deliverAt != $1.deliverAt { return $0.deliverAt < $1.deliverAt }
            if $0.owner != $1.owner { return $0.owner < $1.owner }
            return $0.scheduledId < $1.scheduledId
        }
        var results: [(item: ScheduledMessageListItem, result: ActionResult)] = []
        for item in sorted where visited.insert(Identity(item)).inserted {
            results.append((item, await perform(action, on: item)))
        }
        return results
    }

    func recoveries(
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> [ScheduledMessageActionRecovery] {
        journal.records(owner: owner).filter {
            $0.item.conversation == conversation && $0.item.conversationType == conversationType &&
                !Self.inFlight.contains(Identity($0.item))
        }.sorted { $0.item.deliverAt < $1.item.deliverAt }
    }

    func dismissRecovery(_ recovery: ScheduledMessageActionRecovery) {
        guard !Self.inFlight.contains(Identity(recovery.item)),
              journal.record(for: recovery.item) == recovery else { return }
        journal.remove(item: recovery.item)
    }

    func retry(_ recovery: ScheduledMessageActionRecovery) async -> ActionResult {
        let item = recovery.item
        let action = recovery.action
        let identity = Identity(item)
        guard Self.inFlight.insert(identity).inserted else { return failure(.sendRejected) }
        defer { Self.inFlight.remove(identity) }
        guard journal.record(for: item) == recovery else { return failure(.itemNotFound) }
        if recovery.requiresRefresh {
            await refresh(item)
            return failure(.invalidResponse, recovery: recovery)
        }
        if let error = preflight(action, item: item) {
            return failure(error, recovery: recovery)
        }
        guard let payload = ScheduledMessageActionPayload.make(action, item: item),
              journal.setRequiresRefresh(true, for: item) else {
            return failure(.sendRejected, recovery: recovery)
        }
        return await submit(payload, action: action, item: item)
    }

    private func preflight(_ action: ScheduledMessageAction, item: ScheduledMessageListItem) -> ScheduleError? {
        guard Self.supports(action, on: item) else { return .malformedPayload }
        if let date = deliveryDate(action, item: item), date <= now() { return .notAcceptable }
        return service.validateScheduledAction(action, on: item)
    }

    private func deliveryDate(_ action: ScheduledMessageAction, item: ScheduledMessageListItem) -> Date? {
        switch action {
        case .edit, .editContent: return item.deliverAt
        case .reschedule(let date): return date
        case .delete, .sendNow: return nil
        }
    }

    private func submit(
        _ payload: XMPPMessage,
        action: ScheduledMessageAction,
        item: ScheduledMessageListItem
    ) async -> ActionResult {
        // The journal may have been cleared by account removal while awaiting cancel.
        guard journal.record(for: item) != nil else { return failure(.sendRejected) }
        let result: Result<Void, ScheduleError>
        if let error = preflight(action, item: item) {
            result = .failure(error)
        } else if let date = deliveryDate(action, item: item) {
            let scheduled: Result<XMPPMessageScheduleManager.ScheduledEntry, ScheduleError>
            if item.conversationType == .omemo {
                scheduled = await withCheckedContinuation { continuation in
                    let completion = ScheduledMessageIQCompletion(continuation)
                    service.scheduleOMEMO2PreparedMessage(
                        payload, owner: item.owner, conversation: item.conversation, deliverAt: date,
                        callback: completion.resolve
                    )
                }
            } else {
                scheduled = await request { callback in
                    service.schedulePreparedMessage(payload, for: item, deliverAt: date, callback: callback)
                }
            }
            result = scheduled.map { _ in () }
        } else {
            result = await withCheckedContinuation { continuation in
                service.sendScheduledMessageNow(payload, for: item) { continuation.resume(returning: $0) }
            }
        }
        switch result {
        case .success:
            journal.remove(item: item)
            return .success(())
        case .failure(let error):
            if hasUnknownOutcome(error) {
                await refresh(item)
            } else {
                _ = journal.setRequiresRefresh(false, for: item)
            }
            return failure(error, recovery: journal.record(for: item))
        }
    }

    private func refresh(_ item: ScheduledMessageListItem) async {
        let _: Result<[XMPPMessageScheduleManager.ScheduledEntry], ScheduleError> = await request { callback in
            service.listScheduledMessages(owner: item.owner, conversation: item.conversation,
                                          conversationType: item.conversationType, callback: callback)
        }
    }

    private func request<Value>(
        _ start: (@escaping (Result<Value, ScheduleError>) -> Void) -> String?
    ) async -> Result<Value, ScheduleError> {
        await withCheckedContinuation { continuation in
            let completion = ScheduledMessageIQCompletion(continuation)
            if start(completion.resolve) == nil {
                completion.resolve(.failure(.sendRejected))
            }
        }
    }

    private func hasUnknownOutcome(_ error: ScheduleError) -> Bool {
        switch error {
        case .timeout, .disconnected, .invalidResponse: return true
        default: return false
        }
    }

    private func failure(_ error: ScheduleError, recovery: ScheduledMessageActionRecovery? = nil) -> ActionResult {
        .failure(ScheduledMessageActionFailure(error: error, recovery: recovery))
    }
}

private final class ScheduledMessageIQCompletion<Value> {
    typealias Reply = Result<Value, XMPPMessageScheduleManager.ScheduleError>
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Reply, Never>?

    init(_ continuation: CheckedContinuation<Reply, Never>) {
        self.continuation = continuation
    }

    func resolve(_ reply: Reply) {
        lock.lock()
        let completion = continuation
        continuation = nil
        lock.unlock()
        completion?.resume(returning: reply)
    }
}

enum ScheduledMessageActionPayload {
    static func hasValidIdentity(_ item: ScheduledMessageListItem) -> Bool {
        !item.scheduledId.isEmpty && XMPPJID(string: item.owner)?.bare == item.owner &&
            XMPPJID(string: item.conversation)?.bare == item.conversation
    }

    static func make(_ action: ScheduledMessageAction, item: ScheduledMessageListItem) -> XMPPMessage? {
        guard [.regular, .group, .saved, .omemo].contains(item.conversationType),
              let contentXML = item.contentXML,
              let message = try? XMPPMessage(xmlString: contentXML),
              SCEReceivePolicy.matches(message, name: "message", namespace: SCEReceivePolicy.client),
              message.to?.bare == item.conversation, message.to?.resource == nil,
              message.from == nil || message.from?.bare == item.owner,
              message.attributeStringValue(forName: "type") == "chat",
              !SCEReceivePolicy.containsOMEMO2(message) else { return nil }
        let children = (message.children ?? []).compactMap { $0 as? DDXMLElement }
        guard !children.contains(where: isUnsafeTopLevelChild) else { return nil }
        let bodyElementName = "body"
        let bodies = SCEReceivePolicy.children(of: message, named: bodyElementName, xmlns: SCEReceivePolicy.client)
        guard bodies.count <= 1 else { return nil }
        let originalBody = bodies.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch action {
        case .edit(let text):
            return ScheduledMessageContent.edited(
                message, body: text, retainedAttachmentIDs: nil, addedAttachmentXML: [],
                protected: item.conversationType == .omemo
            )
        case .editContent(let text, let retainedIDs, let addedXML):
            return ScheduledMessageContent.edited(
                message, body: text, retainedAttachmentIDs: retainedIDs, addedAttachmentXML: addedXML,
                protected: item.conversationType == .omemo
            )
        case .reschedule:
            guard !originalBody.isEmpty || children.contains(where: { !isPlainTextChild($0) }) else { return nil }
        case .sendNow:
            let normalized = ScheduledMessageContent.normalizeWebRanges(message)
            guard let body = normalized.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (try? MessageManager.validatePreparedContentSize(normalized)) != nil else { return nil }
            return normalized
        case .delete:
            return nil
        }
        return message
    }

    private static func isUnsafeTopLevelChild(_ child: DDXMLElement) -> Bool {
        let namespace = child.uri ?? ""
        let name = child.localName ?? ""
        return name == "encrypted" || name == "encryption" ||
            namespace == XMPPMessageScheduleManager.namespace ||
            namespace == "http://jabber.org/protocol/address" ||
            namespace == "urn:xmpp:sce:1" || name == "stanza-id" ||
            namespace == "urn:xmpp:forward:0" ||
            SCEReceivePolicy.mamNamespaces.contains(namespace) ||
            (SCEReceivePolicy.carbonNamespaces.contains(namespace) && name != "private")
    }

    private static func isPlainTextChild(_ child: DDXMLElement) -> Bool {
        let plainTextMetadata: [(String, String)] = [
            ("body", SCEReceivePolicy.client), ("origin-id", "urn:xmpp:sid:0"),
            ("private", "urn:xmpp:carbons:2"), ("markable", "urn:xmpp:chat-markers:0")
        ]
        return plainTextMetadata.contains { SCEReceivePolicy.matches(child, name: $0.0, namespace: $0.1) }
    }
}

/// A separate journal makes a cancelled row recoverable without putting it back in the server mirror.
/// A record is written before cancellation. An interrupted write/send leaves a review-only recovery.
final class ScheduledMessageActionJournal {
    static let shared: ScheduledMessageActionJournal = {
        let files = FileManager.default
        let directory: URL
        if HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment) {
            directory = files.temporaryDirectory.appendingPathComponent("ScheduledMessageActions-\(UUID())")
        } else {
            directory = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ScheduledMessageActions", isDirectory: true)
        }
        return ScheduledMessageActionJournal(directory: directory)
    }()

    private struct Record: Codable {
        let owner: String
        let conversation: String
        let conversationType: String
        let scheduledId: String
        let deliverAt: Date
        let status: String
        let bodyPreview: String
        let messageXML: String
        let protectedContentXML: String?
        let action: ScheduledMessageAction
        var requiresRefresh: Bool

        init(item: ScheduledMessageListItem, action: ScheduledMessageAction) {
            owner = item.owner
            conversation = item.conversation
            conversationType = item.conversationType.rawValue
            scheduledId = item.scheduledId
            deliverAt = item.deliverAt
            status = item.status.rawValue
            bodyPreview = item.bodyPreview
            messageXML = item.messageXML
            protectedContentXML = item.protectedContentXML
            self.action = action
            requiresRefresh = true
        }

        var recovery: ScheduledMessageActionRecovery? {
            guard let type = ClientSynchronizationManager.ConversationType(rawValue: conversationType),
                  let status = XMPPMessageScheduleStorageItem.Status(rawValue: status) else { return nil }
            return ScheduledMessageActionRecovery(
                item: ScheduledMessageListItem(scheduledId: scheduledId, deliverAt: deliverAt, status: status,
                    bodyPreview: bodyPreview, owner: owner, conversation: conversation,
                    conversationType: type, messageXML: messageXML, protectedContentXML: protectedContentXML),
                action: action, requiresRefresh: requiresRefresh
            )
        }
    }

    private static let maximumBytes = 1_048_576
    private let directory: URL
    private let lock = NSLock()
    private var cachedRecords: [String: [String: Record]] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func records(owner: String) -> [ScheduledMessageActionRecovery] {
        withLock {
            (try? read(owner: owner))?.values.compactMap(\.recovery) ?? []
        }
    }

    func record(for item: ScheduledMessageListItem) -> ScheduledMessageActionRecovery? {
        withLock {
            (try? read(owner: item.owner))?[item.scheduledId]?.recovery
        }
    }

    func begin(item: ScheduledMessageListItem, action: ScheduledMessageAction) -> Bool {
        update(owner: item.owner) { records in
            guard records[item.scheduledId] == nil, records.count < 64 else { return false }
            records[item.scheduledId] = Record(item: item, action: action)
            return true
        }
    }

    func setRequiresRefresh(_ required: Bool, for item: ScheduledMessageListItem) -> Bool {
        update(owner: item.owner) { records in
            guard records[item.scheduledId] != nil else { return false }
            records[item.scheduledId]?.requiresRefresh = required
            return true
        }
    }

    func remove(item: ScheduledMessageListItem) {
        _ = update(owner: item.owner) { $0.removeValue(forKey: item.scheduledId) != nil }
    }

    func invalidate(forOwner owner: String) throws {
        try withLock {
            try removeFile(for: owner)
            cachedRecords.removeValue(forKey: owner)
        }
    }

    func invalidateAll() throws {
        try withLock {
            cachedRecords.removeAll()
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                if !Self.isMissingFile(error) { throw error }
            }
        }
    }

    private func withLock<Value>(_ work: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    private func update(owner: String, _ mutate: (inout [String: Record]) -> Bool) -> Bool {
        withLock {
            do {
                var records = try read(owner: owner)
                guard mutate(&records) else { return false }
                try write(records, owner: owner)
                cachedRecords[owner] = records
                return true
            } catch {
                return false
            }
        }
    }

    private func file(for owner: String) -> URL {
        let digest = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest, isDirectory: false)
    }

    private func read(owner: String) throws -> [String: Record] {
        if let records = cachedRecords[owner] { return records }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file(for: owner))
        } catch {
            if Self.isMissingFile(error) {
                cachedRecords[owner] = [:]
                return [:]
            }
            throw error
        }
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: Self.maximumBytes + 1), data.count <= Self.maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let records = try JSONDecoder().decode([String: Record].self, from: data)
        guard records.allSatisfy({ $0.key == $0.value.scheduledId && $0.value.owner == owner }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        cachedRecords[owner] = records
        return records
    }

    private func write(_ records: [String: Record], owner: String) throws {
        if records.isEmpty {
            try removeFile(for: owner)
            return
        }
        let data = try JSONEncoder().encode(records)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        try data.write(to: file(for: owner), options: [.atomic, .completeFileProtection])
    }

    private func removeFile(for owner: String) throws {
        do {
            try FileManager.default.removeItem(at: file(for: owner))
        } catch {
            if !Self.isMissingFile(error) { throw error }
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let underlying = error as NSError
        return underlying.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(underlying.code)
    }
}
