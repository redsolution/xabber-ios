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
import XMPPFramework
import KissXML
import RealmSwift
import RxSwift

/// TODO: fix wrong message count when response missed

struct MessageArchivePageEndState: Equatable {
    let queryExhausted: Bool
    let archiveEnded: Bool
    let persistedMessageCount: Int
    let requestCursorId: String?

    init(
        queryExhausted: Bool,
        archiveEnded: Bool,
        persistedMessageCount: Int,
        requestCursorId: String? = nil
    ) {
        self.queryExhausted = queryExhausted
        self.archiveEnded = archiveEnded
        self.persistedMessageCount = persistedMessageCount
        self.requestCursorId = requestCursorId
    }
}

struct MessageArchiveEndPageEvent: Equatable {
    enum StreamKind: String {
        case primary
        case uiAction
        case background
        case unknown
    }

    enum Source: String {
        case localCallback
        case fallbackCallback
        case unroutedFinalIQ
        case unroutedErrorIQ
    }

    let owner: String
    let queryId: String
    let state: MessageArchivePageEndState
    let first: String
    let last: String
    let count: Int
    let streamKind: StreamKind
    let source: Source
}

enum MessageArchiveRequestFailureReason: String {
    case timeout
    case uiActionDisconnect
    case requestStartFailed
    case serverError
    case malformedResponse
}

struct MessageArchiveRequestFailureEvent: Equatable {
    let owner: String
    let queryId: String
    let streamKind: MessageArchiveEndPageEvent.StreamKind
    let reason: MessageArchiveRequestFailureReason
    let errorDescription: String?
    let pendingQueryCount: Int
}

enum ChatArchiveDebugTrace {
    typealias Sink = (String) -> Void
    static let sampleEveryEnvironmentKey = "XABBER_CHAT_ARCHIVE_TRACE_SAMPLE_EVERY"
    static let productionSampleEvery = 8

    static func resolvedSampleEvery(environment: [String: String]) -> Int {
        guard let rawValue = environment[sampleEveryEnvironmentKey],
              let value = Int(rawValue),
              value > 0 else {
            return productionSampleEvery
        }
        return value
    }

    #if DEBUG
    private struct Configuration {
        var enabled: Bool
        var sampleEvery: Int
        var invocationCount: UInt64
        let sink: Sink
    }

    private static let configurationLock = NSLock()
    private static var configuration = defaultConfiguration

    private static var defaultConfiguration: Configuration {
        Configuration(
            enabled: true,
            sampleEvery: resolvedSampleEvery(
                environment: ProcessInfo.processInfo.environment
            ),
            invocationCount: 0,
            sink: { DDLogDebug($0) }
        )
    }
    #endif

    /// Event and field builders remain unevaluated in Release, while disabled,
    /// and for unsampled calls. Only numeric/boolean values are admitted: all
    /// string identities (owner, JID, body, URL/path, query/message/archive ID)
    /// are omitted even if a caller passes them accidentally.
    @inline(__always)
    static func log(
        _ event: @autoclosure () -> String,
        _ fields: @autoclosure () -> [(String, Any?)] = []
    ) {
        #if DEBUG
        guard let sink = sinkForNextInvocation() else {
            return
        }

        var parts = [
            "CHAT_ARCHIVE_TRACE",
            "event=\(sanitizedLabel(event(), fallback: "invalid-event"))",
            "thread=\(Thread.isMainThread ? "main" : "background")"
        ]
        for (key, optionalValue) in fields() {
            guard let value = optionalValue,
                  let formattedValue = privacySafeValue(value) else {
                continue
            }
            parts.append(
                "\(sanitizedLabel(key, fallback: "metric"))=\(formattedValue)"
            )
        }
        sink(parts.joined(separator: " "))
        #endif
    }

    static func configureForTesting(
        enabled: Bool,
        sampleEvery: Int,
        sink: @escaping Sink
    ) {
        #if DEBUG
        configurationLock.lock()
        configuration = Configuration(
            enabled: enabled,
            sampleEvery: max(1, sampleEvery),
            invocationCount: 0,
            sink: sink
        )
        configurationLock.unlock()
        #endif
    }

    static func resetTestingConfiguration() {
        #if DEBUG
        configurationLock.lock()
        configuration = defaultConfiguration
        configurationLock.unlock()
        #endif
    }

    static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    #if DEBUG
    private static func sinkForNextInvocation() -> Sink? {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        guard configuration.enabled else {
            return nil
        }
        configuration.invocationCount &+= 1
        guard configuration.invocationCount.isMultiple(of: UInt64(configuration.sampleEvery)) else {
            return nil
        }
        return configuration.sink
    }

    private static func privacySafeValue(_ value: Any) -> String? {
        switch value {
        case let value as Bool:
            return value ? "true" : "false"
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func sanitizedLabel(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard value.isNotEmpty,
              value.count <= 64,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            return fallback
        }
        return value
    }
    #endif
}

enum MessageArchiveEndPageDispatcher {
    enum Delivery: Equatable {
        case mainAsync
        case synchronous
    }

    struct Token: Hashable {
        fileprivate let id: UUID
        fileprivate let owner: String
        fileprivate let queryId: String
    }

    private struct RegisteredHandler {
        let delivery: Delivery
        let body: (MessageArchiveEndPageEvent) -> Void
    }

    private static let lock = NSLock()
    private static var handlersByKey: [String: [UUID: RegisteredHandler]] = [:]
    private static var acceptedSynchronousDeliveryCountByKey: [String: Int] = [:]
    #if DEBUG
    private static var synchronousDeliveryAcceptedHookForTests: ((MessageArchiveEndPageEvent) -> Void)?
    #endif

    private static func key(owner: String, queryId: String) -> String {
        "\(owner)\u{1F}archive-end-page\u{1F}\(queryId)"
    }

    @discardableResult
    static func register(
        owner: String,
        queryId: String,
        delivery: Delivery = .mainAsync,
        handler: @escaping (MessageArchiveEndPageEvent) -> Void
    ) -> Token {
        let token = Token(id: UUID(), owner: owner, queryId: queryId)
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return token
        }

        lock.lock()
        handlersByKey[key(owner: owner, queryId: queryId), default: [:]][token.id] = RegisteredHandler(
            delivery: delivery,
            body: handler
        )
        let handlerCount = handlersByKey[key(owner: owner, queryId: queryId)]?.count ?? 0
        lock.unlock()
        ChatArchiveDebugTrace.log("endPageDispatcherRegister", [
            ("owner", owner),
            ("queryId", queryId),
            ("handlerCount", handlerCount)
        ])
        return token
    }

    static func unregister(_ token: Token) {
        guard token.owner.isNotEmpty,
              token.queryId.isNotEmpty else {
            return
        }

        lock.lock()
        let key = key(owner: token.owner, queryId: token.queryId)
        handlersByKey[key]?.removeValue(forKey: token.id)
        if handlersByKey[key]?.isEmpty == true {
            handlersByKey.removeValue(forKey: key)
        }
        lock.unlock()
        ChatArchiveDebugTrace.log("endPageDispatcherUnregister", [
            ("owner", token.owner),
            ("queryId", token.queryId)
        ])
    }

    static func hasHandler(owner: String, queryId: String) -> Bool {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return false
        }

        lock.lock()
        let hasHandler = handlersByKey[key(owner: owner, queryId: queryId)]?.isEmpty == false
        lock.unlock()
        return hasHandler
    }

    static func hasAcceptedSynchronousDelivery(owner: String, queryId: String) -> Bool {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return false
        }

        lock.lock()
        let isAccepted = (acceptedSynchronousDeliveryCountByKey[
            key(owner: owner, queryId: queryId)
        ] ?? 0) > 0
        lock.unlock()
        return isAccepted
    }

    #if DEBUG
    static func setSynchronousDeliveryAcceptedHookForTests(
        _ hook: ((MessageArchiveEndPageEvent) -> Void)?
    ) {
        lock.lock()
        synchronousDeliveryAcceptedHookForTests = hook
        lock.unlock()
    }
    #endif

    @discardableResult
    static func publish(_ event: MessageArchiveEndPageEvent) -> Bool {
        guard event.owner.isNotEmpty,
              event.queryId.isNotEmpty else {
            return false
        }

        let eventKey = key(owner: event.owner, queryId: event.queryId)
        let acceptedHook: ((MessageArchiveEndPageEvent) -> Void)?
        lock.lock()
        let handlers = handlersByKey.removeValue(forKey: eventKey)
        let hasSynchronousHandlers = handlers?.values.contains {
            $0.delivery == .synchronous
        } == true
        if hasSynchronousHandlers {
            acceptedSynchronousDeliveryCountByKey[eventKey, default: 0] += 1
        }
        #if DEBUG
        acceptedHook = synchronousDeliveryAcceptedHookForTests
        #else
        acceptedHook = nil
        #endif
        lock.unlock()

        guard let handlers,
              !handlers.isEmpty else {
            ChatArchiveDebugTrace.log("endPageDispatcherPublishMiss", [
                ("owner", event.owner),
                ("queryId", event.queryId),
                ("source", event.source.rawValue),
                ("streamKind", event.streamKind.rawValue),
                ("count", event.count)
            ])
            return false
        }

        let enqueuedAt = Date()
        ChatArchiveDebugTrace.log("endPageDispatcherPublish", [
            ("owner", event.owner),
            ("queryId", event.queryId),
            ("source", event.source.rawValue),
            ("streamKind", event.streamKind.rawValue),
            ("count", event.count),
            ("handlerCount", handlers.count)
        ])
        let synchronousHandlers = handlers.values
            .filter { $0.delivery == .synchronous }
            .map(\.body)
        let mainHandlers = handlers.values
            .filter { $0.delivery == .mainAsync }
            .map(\.body)
        if hasSynchronousHandlers {
            acceptedHook?(event)
        }
        synchronousHandlers.forEach { $0(event) }
        if hasSynchronousHandlers {
            lock.lock()
            let remainingAcceptedDeliveries = max(
                0,
                (acceptedSynchronousDeliveryCountByKey[eventKey] ?? 1) - 1
            )
            if remainingAcceptedDeliveries == 0 {
                acceptedSynchronousDeliveryCountByKey.removeValue(forKey: eventKey)
            } else {
                acceptedSynchronousDeliveryCountByKey[eventKey] = remainingAcceptedDeliveries
            }
            lock.unlock()
        }
        guard mainHandlers.isNotEmpty else {
            return true
        }
        DispatchQueue.main.async {
            ChatArchiveDebugTrace.log("endPageDispatcherMainHandlerStart", [
                ("owner", event.owner),
                ("queryId", event.queryId),
                ("source", event.source.rawValue),
                ("mainWaitMs", ChatArchiveDebugTrace.milliseconds(since: enqueuedAt)),
                ("handlerCount", mainHandlers.count)
            ])
            let startedAt = Date()
            mainHandlers.forEach { $0(event) }
            ChatArchiveDebugTrace.log("endPageDispatcherMainHandlerFinish", [
                ("owner", event.owner),
                ("queryId", event.queryId),
                ("source", event.source.rawValue),
                ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt))
            ])
        }
        return true
    }

    static func resetForTests() {
        lock.lock()
        handlersByKey.removeAll()
        acceptedSynchronousDeliveryCountByKey.removeAll()
        #if DEBUG
        synchronousDeliveryAcceptedHookForTests = nil
        #endif
        lock.unlock()
    }
}

enum MessageArchiveRequestFailureDispatcher {
    enum Delivery: Equatable {
        case mainAsync
        case synchronous
    }

    struct Token: Hashable {
        fileprivate let id: UUID
        fileprivate let owner: String
        fileprivate let queryId: String
    }

    private struct RegisteredHandler {
        let delivery: Delivery
        let body: (MessageArchiveRequestFailureEvent) -> Void
    }

    private static let lock = NSLock()
    private static var handlersByKey: [String: [UUID: RegisteredHandler]] = [:]

    private static func key(owner: String, queryId: String) -> String {
        "\(owner)\u{1F}archive-request-failure\u{1F}\(queryId)"
    }

    @discardableResult
    static func register(
        owner: String,
        queryId: String,
        delivery: Delivery = .mainAsync,
        handler: @escaping (MessageArchiveRequestFailureEvent) -> Void
    ) -> Token {
        let token = Token(id: UUID(), owner: owner, queryId: queryId)
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return token
        }

        lock.lock()
        handlersByKey[key(owner: owner, queryId: queryId), default: [:]][token.id] = RegisteredHandler(
            delivery: delivery,
            body: handler
        )
        let handlerCount = handlersByKey[key(owner: owner, queryId: queryId)]?.count ?? 0
        lock.unlock()
        ChatArchiveDebugTrace.log("requestFailureDispatcherRegister", [
            ("owner", owner),
            ("queryId", queryId),
            ("handlerCount", handlerCount)
        ])
        return token
    }

    static func unregister(_ token: Token) {
        guard token.owner.isNotEmpty,
              token.queryId.isNotEmpty else {
            return
        }

        lock.lock()
        let key = key(owner: token.owner, queryId: token.queryId)
        handlersByKey[key]?.removeValue(forKey: token.id)
        if handlersByKey[key]?.isEmpty == true {
            handlersByKey.removeValue(forKey: key)
        }
        lock.unlock()
        ChatArchiveDebugTrace.log("requestFailureDispatcherUnregister", [
            ("owner", token.owner),
            ("queryId", token.queryId)
        ])
    }

    static func hasHandler(owner: String, queryId: String) -> Bool {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return false
        }

        lock.lock()
        let hasHandler = handlersByKey[key(owner: owner, queryId: queryId)]?.isEmpty == false
        lock.unlock()
        return hasHandler
    }

    @discardableResult
    static func publish(_ event: MessageArchiveRequestFailureEvent) -> Bool {
        guard event.owner.isNotEmpty,
              event.queryId.isNotEmpty else {
            return false
        }

        lock.lock()
        let handlers = handlersByKey.removeValue(forKey: key(owner: event.owner, queryId: event.queryId))
        lock.unlock()

        guard let handlers,
              !handlers.isEmpty else {
            ChatArchiveDebugTrace.log("requestFailureDispatcherPublishMiss", [
                ("owner", event.owner),
                ("queryId", event.queryId),
                ("reason", event.reason.rawValue),
                ("streamKind", event.streamKind.rawValue),
                ("pendingQueryCount", event.pendingQueryCount)
            ])
            return false
        }

        let enqueuedAt = Date()
        ChatArchiveDebugTrace.log("requestFailureDispatcherPublish", [
            ("owner", event.owner),
            ("queryId", event.queryId),
            ("reason", event.reason.rawValue),
            ("streamKind", event.streamKind.rawValue),
            ("pendingQueryCount", event.pendingQueryCount),
            ("handlerCount", handlers.count)
        ])
        let synchronousHandlers = handlers.values
            .filter { $0.delivery == .synchronous }
            .map(\.body)
        let mainHandlers = handlers.values
            .filter { $0.delivery == .mainAsync }
            .map(\.body)
        synchronousHandlers.forEach { $0(event) }
        guard mainHandlers.isNotEmpty else {
            return true
        }
        DispatchQueue.main.async {
            ChatArchiveDebugTrace.log("requestFailureDispatcherMainHandlerStart", [
                ("owner", event.owner),
                ("queryId", event.queryId),
                ("reason", event.reason.rawValue),
                ("mainWaitMs", ChatArchiveDebugTrace.milliseconds(since: enqueuedAt)),
                ("handlerCount", mainHandlers.count)
            ])
            let startedAt = Date()
            mainHandlers.forEach { $0(event) }
            ChatArchiveDebugTrace.log("requestFailureDispatcherMainHandlerFinish", [
                ("owner", event.owner),
                ("queryId", event.queryId),
                ("reason", event.reason.rawValue),
                ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt))
            ])
        }
        return true
    }

    static func resetForTests() {
        lock.lock()
        handlersByKey.removeAll()
        lock.unlock()
    }
}

/// One-shot, query-scoped preparation barrier for terminal MAM failures.
///
/// Archive consumers use this barrier to durably flush a retained partial
/// page without blocking either the XMPP stream queue or the main queue. The
/// transport callback/query remains registered until every matching handler
/// acknowledges its terminal work. Ordinary failure publication happens only
/// after that acknowledgement.
enum MessageArchiveRequestFailurePreparationDispatcher {
    struct Token: Hashable {
        fileprivate let id: UUID
        fileprivate let owner: String
        fileprivate let queryId: String
    }

    private final class HandlerAcknowledgement {
        private let lock = NSLock()
        private var didAcknowledge = false
        private let body: () -> Void

        init(_ body: @escaping () -> Void) {
            self.body = body
        }

        func acknowledge() {
            lock.lock()
            guard !didAcknowledge else {
                lock.unlock()
                return
            }
            didAcknowledge = true
            lock.unlock()
            body()
        }
    }

    private final class PreparationGroup {
        private let lock = NSLock()
        private var remaining: Int
        private var didComplete = false
        private let completion: () -> Void

        init(count: Int, completion: @escaping () -> Void) {
            self.remaining = count
            self.completion = completion
        }

        func makeAcknowledgement() -> () -> Void {
            let acknowledgement = HandlerAcknowledgement {
                self.finishOne()
            }
            return acknowledgement.acknowledge
        }

        private func finishOne() {
            let shouldComplete: Bool
            lock.lock()
            remaining = max(0, remaining - 1)
            shouldComplete = remaining == 0 && !didComplete
            if shouldComplete {
                didComplete = true
            }
            lock.unlock()
            if shouldComplete {
                completion()
            }
        }
    }

    private typealias Handler = (
        MessageArchiveRequestFailureEvent,
        @escaping () -> Void
    ) -> Void

    private static let lock = NSLock()
    private static var handlersByKey: [String: [UUID: Handler]] = [:]

    private static func key(owner: String, queryId: String) -> String {
        "\(owner)\u{1F}archive-request-failure-preparation\u{1F}\(queryId)"
    }

    @discardableResult
    static func register(
        owner: String,
        queryId: String,
        handler: @escaping (
            MessageArchiveRequestFailureEvent,
            @escaping () -> Void
        ) -> Void
    ) -> Token {
        let token = Token(id: UUID(), owner: owner, queryId: queryId)
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return token
        }

        lock.lock()
        handlersByKey[key(owner: owner, queryId: queryId), default: [:]][token.id] = handler
        lock.unlock()
        return token
    }

    static func unregister(_ token: Token) {
        guard token.owner.isNotEmpty,
              token.queryId.isNotEmpty else {
            return
        }

        lock.lock()
        let key = key(owner: token.owner, queryId: token.queryId)
        handlersByKey[key]?.removeValue(forKey: token.id)
        if handlersByKey[key]?.isEmpty == true {
            handlersByKey.removeValue(forKey: key)
        }
        lock.unlock()
    }

    /// Starts all matching preparations. Missing handlers deliberately use an
    /// immediate fallback so search, timestamp lookups, and unowned archive
    /// requests retain their established cleanup behavior.
    @discardableResult
    static func prepare(
        _ event: MessageArchiveRequestFailureEvent,
        completion: @escaping () -> Void
    ) -> Bool {
        guard event.owner.isNotEmpty,
              event.queryId.isNotEmpty else {
            completion()
            return false
        }

        lock.lock()
        let handlers = handlersByKey.removeValue(
            forKey: key(owner: event.owner, queryId: event.queryId)
        )?.values.map { $0 } ?? []
        lock.unlock()

        guard handlers.isNotEmpty else {
            completion()
            return false
        }

        let group = PreparationGroup(count: handlers.count, completion: completion)
        handlers.forEach { handler in
            handler(event, group.makeAcknowledgement())
        }
        return true
    }

    static func resetForTests() {
        lock.lock()
        handlersByKey.removeAll()
        lock.unlock()
    }
}

protocol TemporaryMessageReceiverProtocol {
    func didReceiveMessage(_ item: MessageStorageItem, queryId: String)
    func didReceiveEndPage(queryId: String, state: MessageArchivePageEndState, first: String, last: String, count: Int)
}

/// Arbitrates the only two legal terminals of a query-scoped persistence
/// flush. The winner owns the deferred archive commit; a late Realm callback
/// after timeout is deliberately ignored so it cannot restore readiness.
final class ArchivePersistenceTerminalGate {
    private enum State: Equatable {
        case idle
        case waiting
        case resolved
    }

    private let lock = NSLock()
    private let timeout: TimeInterval
    private let queue: DispatchQueue
    private var state: State = .idle
    private var timeoutWorkItem: DispatchWorkItem?
    private var timeoutHandler: (() -> Void)?

    init(
        timeout: TimeInterval,
        queue: DispatchQueue = DispatchQueue.global(qos: .utility)
    ) {
        self.timeout = max(0, timeout)
        self.queue = queue
    }

    deinit {
        timeoutWorkItem?.cancel()
    }

    @discardableResult
    func arm(onTimeout: @escaping () -> Void) -> Bool {
        let workItem: DispatchWorkItem
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            return false
        }
        state = .waiting
        timeoutHandler = onTimeout
        workItem = DispatchWorkItem { [weak self] in
            _ = self?.resolveTimeout()
        }
        timeoutWorkItem = workItem
        lock.unlock()

        queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
        return true
    }

    /// Returns true only to the first persistence callback that beats timeout.
    @discardableResult
    func claimPersistenceTerminal() -> Bool {
        let workItem: DispatchWorkItem?
        lock.lock()
        guard state == .waiting else {
            lock.unlock()
            return false
        }
        state = .resolved
        workItem = timeoutWorkItem
        timeoutWorkItem = nil
        timeoutHandler = nil
        lock.unlock()
        workItem?.cancel()
        return true
    }

    /// Deterministic hook used by regression tests; production timeout uses
    /// the same locked resolution path.
    @discardableResult
    func resolveTimeoutForTests() -> Bool {
        resolveTimeout()
    }

    @discardableResult
    private func resolveTimeout() -> Bool {
        let handler: (() -> Void)?
        lock.lock()
        guard state == .waiting else {
            lock.unlock()
            return false
        }
        state = .resolved
        timeoutWorkItem = nil
        handler = timeoutHandler
        timeoutHandler = nil
        lock.unlock()
        handler?()
        return true
    }
}

struct RegularIdleBackfillAttemptToken: Equatable {
    private let id = UUID()
    fileprivate let isAutomaticRetry: Bool

    fileprivate init(isAutomaticRetry: Bool = false) {
        self.isAutomaticRetry = isAutomaticRetry
    }
}

struct RegularIdleBackfillTriggerState: Equatable {
    private(set) var hasPendingTrigger = false
    private(set) var isAttemptScheduled = false
    private(set) var activeAttemptToken: RegularIdleBackfillAttemptToken?
    private var nextAttemptIsAutomaticRetry = false

    var isInProgress: Bool {
        activeAttemptToken != nil
    }

    mutating func registerExplicitTrigger() -> Bool {
        hasPendingTrigger = true
        // A new explicit trigger starts a fresh retry chain and supersedes a
        // queued automatic retry for the same idle pump.
        nextAttemptIsAutomaticRetry = false
        guard !isInProgress,
              !isAttemptScheduled else {
            return false
        }
        isAttemptScheduled = true
        return true
    }

    mutating func beginScheduledAttempt() -> RegularIdleBackfillAttemptToken? {
        guard isAttemptScheduled else {
            return nil
        }
        isAttemptScheduled = false
        guard activeAttemptToken == nil,
              hasPendingTrigger else {
            return nil
        }
        hasPendingTrigger = false
        let token = RegularIdleBackfillAttemptToken(
            isAutomaticRetry: nextAttemptIsAutomaticRetry
        )
        nextAttemptIsAutomaticRetry = false
        activeAttemptToken = token
        return token
    }

    mutating func finishAttempt(
        _ token: RegularIdleBackfillAttemptToken,
        requiresRetry: Bool = false
    ) -> Bool {
        guard activeAttemptToken == token else {
            return false
        }
        activeAttemptToken = nil
        if requiresRetry,
           !token.isAutomaticRetry,
           !hasPendingTrigger {
            hasPendingTrigger = true
            nextAttemptIsAutomaticRetry = true
        }
        guard hasPendingTrigger,
              !isAttemptScheduled else {
            return false
        }
        isAttemptScheduled = true
        return true
    }

    mutating func reset() {
        hasPendingTrigger = false
        isAttemptScheduled = false
        activeAttemptToken = nil
        nextAttemptIsAutomaticRetry = false
    }
}

class MessageArchiveManager: AbstractXMPPManager {

    enum HistoryCursorPolicy {
        static func shouldPersistCursor(for purpose: MessageArchiveManager.RequestPurpose) -> Bool {
            [.bootstrap, .pageOlder].contains(purpose)
        }

        static func persistedOlderCursorId(
            purpose: MessageArchiveManager.RequestPurpose,
            first: String,
            last: String,
            current: String?
        ) -> String? {
            guard shouldPersistCursor(for: purpose) else {
                return current
            }

            // iOS older-history requests use flip-page, so RSM `last` is the
            // oldest archived id in the fetched page and is the correct cursor
            // for the next `before=` request.
            if last.isNotEmpty {
                return last
            }

            guard first.isNotEmpty else {
                return current
            }

            return first
        }
    }

    enum ArchiveEndPolicy {
        static func canCommitCoverage(for purpose: RequestPurpose) -> Bool {
            purpose.isArchiveHistoryProducing
        }
    }

    enum ConversationTypeFilterPolicy {
        static func shouldIncludeConversationTypeField(
            conversationType: ClientSynchronizationManager.ConversationType,
            purpose: RequestPurpose,
            isGroupchat: Bool,
            isExtendedArchiveAvailable: Bool
        ) -> Bool {
            guard !isGroupchat, isExtendedArchiveAvailable else {
                return false
            }

            if conversationType == .regular {
                return purpose == .snapshotRepair
            }

            return true
        }
    }

    enum ChatBootstrapRequestPolicy {
        static func shouldStartInitialBootstrap(
            isSynced: Bool,
            isInitialArchiveLoaded: Bool,
            localMessageCount: Int,
            hasKnownRemoteBoundary: Bool = false
        ) -> Bool {
            if localMessageCount == 0, hasKnownRemoteBoundary {
                return true
            }

            if !isSynced {
                return true
            }

            if !isInitialArchiveLoaded {
                return true
            }

            return false
        }
    }

    struct RequestCallbacks {
        let onMessage: ((MessageStorageItem, String) -> Void)?
        let onEndPage: ((String, MessageArchivePageEndState, String, String, Int) -> Void)?
        let onFailure: ((MessageArchiveRequestFailureEvent) -> Void)?
        let onSearchTerminal: ((String, ChatSearchArchiveSession.Terminal) -> Void)?
        let onSearchContinuationAvailable: ((String, String) -> Void)?
        let onSearchContinuationStarted: ((String, String) -> Void)?

        init(
            onMessage: ((MessageStorageItem, String) -> Void)? = nil,
            onEndPage: ((String, MessageArchivePageEndState, String, String, Int) -> Void)? = nil,
            onFailure: ((MessageArchiveRequestFailureEvent) -> Void)? = nil,
            onSearchTerminal: ((String, ChatSearchArchiveSession.Terminal) -> Void)? = nil,
            onSearchContinuationAvailable: ((String, String) -> Void)? = nil,
            onSearchContinuationStarted: ((String, String) -> Void)? = nil
        ) {
            self.onMessage = onMessage
            self.onEndPage = onEndPage
            self.onFailure = onFailure
            self.onSearchTerminal = onSearchTerminal
            self.onSearchContinuationAvailable = onSearchContinuationAvailable
            self.onSearchContinuationStarted = onSearchContinuationStarted
        }

        static let none = RequestCallbacks()
    }

    enum SyncChatStartResult: Equatable {
        case bootstrapStarted(queryId: String)
        case gapRepairOnly
        case noop
    }

    enum DeferredArchiveCommitRejection: Equatable {
        case persistenceFailed(failedRows: Int)
        case missingPersistenceProof
        case malformedCoverageRange
        case storageFailure
    }

    enum DeferredArchiveCommitResult: Equatable {
        case committed
        case committedNeedsFollowUpRepair
        case missingDescriptor
        case rejected(DeferredArchiveCommitRejection)
    }

    private enum DeferredArchiveTracePhase {
        case prepared
        case committed
        case committedNeedsRepair
        case failed
        case aborted
    }
    
    enum Tags: String {
        case image = "image"
        case audio = "audio"
        case video = "video"
        case document = "document"
        case sticker = "sticker"
        case voice = "voice"
        case geo = "geo"
        case voip = "voip"
        case invite = "invite"
    }

    enum RequestPurpose: Equatable, Hashable {
        case bootstrap
        case pageOlder
        case pageNewer
        case jump
        case gapRepair
        case snapshotRepair
        case search
        case timestampLookup
        case latest
        case media
        case inviteRecovery

        var marksInitialArchiveLoaded: Bool {
            self == .bootstrap
        }

        var isArchiveHistoryProducing: Bool {
            switch self {
            case .bootstrap, .pageOlder, .pageNewer, .jump, .gapRepair, .snapshotRepair:
                return true
            case .search, .timestampLookup, .latest, .media, .inviteRecovery:
                return false
            }
        }

        var routesMamServerErrorAsRequestFailure: Bool {
            switch self {
            case .bootstrap, .pageOlder, .pageNewer, .gapRepair, .snapshotRepair, .search, .timestampLookup:
                return true
            case .jump, .latest, .media, .inviteRecovery:
                return false
            }
        }
    }

    struct PageRequestConfiguration: Equatable {
        let nextPage: String?
        let prevPage: String?
        let max: Int
    }

    enum RegularChatArchiveRequestKind: Equatable {
        case bootstrap
        case older
        case newer
        case exactAnchor
        case dateWindow
        case gapRepair
        case snapshotRepair
    }

    enum RegularArchiveGapRepairDirection {
        case older
        case newer
    }

    enum RegularChatArchiveRequestPriority {
        case interactive
        case background
        case idle
    }

    struct RegularChatArchiveRequestPlan: Equatable {
        let kind: RegularChatArchiveRequestKind
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType
        let purpose: RequestPurpose
        let nextPage: String?
        let prevPage: String?
        let ids: [String]?
        let start: Date?
        let end: Date?
        let max: Int
        let usesServerArchiveId: Bool
        let coverageUpdateKind: RegularArchiveCoverageUpdateKind
    }

    struct SnapshotRepairTarget: Hashable {
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType

        func deduplicationKey(owner: String) -> String {
            ChatInitialBootstrapRequestKey(
                owner: owner,
                jid: jid,
                conversationType: conversationType
            ).schedulerDeduplicationKey
        }
    }

    struct RegularChatArchiveRequestKey: Hashable {
        let jid: String
        let conversationTypeRaw: String
        let purpose: RequestPurpose
        let nextPage: String?
        let prevPage: String?
        let ids: [String]?
        let startTime: TimeInterval?
        let endTime: TimeInterval?
        let max: Int
    }

    private struct ArchiveDateConstraint {
        let start: Date?
        let shouldSkipRequest: Bool
    }

    static func newestBootstrapPageRequest(pageSize: Int) -> PageRequestConfiguration {
        PageRequestConfiguration(nextPage: "", prevPage: nil, max: pageSize)
    }

    static func olderPageRequest(messageId: String?, pageSize: Int) -> PageRequestConfiguration {
        PageRequestConfiguration(
            nextPage: (messageId?.isNotEmpty ?? false) ? messageId : "",
            prevPage: nil,
            max: pageSize
        )
    }

    static func newerPageRequest(messageId: String, pageSize: Int) -> PageRequestConfiguration {
        PageRequestConfiguration(nextPage: nil, prevPage: messageId, max: pageSize)
    }

    static func regularArchivePageSize(requested: Int?, defaultPageSize: Int = ChatHistoryPagingConfiguration.pageSize) -> Int {
        min(max(requested ?? defaultPageSize, 1), ChatHistoryPagingConfiguration.pageSize)
    }

    static func regularBootstrapRequestPlan(jid: String, pageSize: Int) -> RegularChatArchiveRequestPlan {
        let request = newestBootstrapPageRequest(pageSize: pageSize)
        return RegularChatArchiveRequestPlan(
            kind: .bootstrap,
            jid: jid,
            conversationType: .regular,
            purpose: .bootstrap,
            nextPage: request.nextPage,
            prevPage: request.prevPage,
            ids: nil,
            start: nil,
            end: nil,
            max: request.max,
            usesServerArchiveId: false,
            coverageUpdateKind: .bootstrapNewest
        )
    }

    static func regularOlderRequestPlan(jid: String, oldestLoadedArchiveId: String?, pageSize: Int) -> RegularChatArchiveRequestPlan {
        let request = olderPageRequest(messageId: oldestLoadedArchiveId, pageSize: pageSize)
        return RegularChatArchiveRequestPlan(
            kind: .older,
            jid: jid,
            conversationType: .regular,
            purpose: .pageOlder,
            nextPage: request.nextPage,
            prevPage: request.prevPage,
            ids: nil,
            start: nil,
            end: nil,
            max: request.max,
            usesServerArchiveId: oldestLoadedArchiveId?.isNotEmpty == true,
            coverageUpdateKind: .pageOlder(cursorArchiveId: oldestLoadedArchiveId)
        )
    }

    static func regularNewerRequestPlan(jid: String, newestLoadedArchiveId: String, pageSize: Int) -> RegularChatArchiveRequestPlan {
        let request = newerPageRequest(messageId: newestLoadedArchiveId, pageSize: pageSize)
        return RegularChatArchiveRequestPlan(
            kind: .newer,
            jid: jid,
            conversationType: .regular,
            purpose: .pageNewer,
            nextPage: request.nextPage,
            prevPage: request.prevPage,
            ids: nil,
            start: nil,
            end: nil,
            max: request.max,
            usesServerArchiveId: true,
            coverageUpdateKind: .pageNewer(cursorArchiveId: newestLoadedArchiveId)
        )
    }

    static func regularExactAnchorRequestPlan(jid: String, archivedId: String) -> RegularChatArchiveRequestPlan {
        RegularChatArchiveRequestPlan(
            kind: .exactAnchor,
            jid: jid,
            conversationType: .regular,
            purpose: .jump,
            nextPage: nil,
            prevPage: nil,
            ids: [archivedId],
            start: nil,
            end: nil,
            max: 1,
            usesServerArchiveId: true,
            coverageUpdateKind: .disjointWindow
        )
    }

    static func regularDateWindowAnchorRequestPlan(jid: String, start: Date, end: Date, max: Int) -> RegularChatArchiveRequestPlan {
        RegularChatArchiveRequestPlan(
            kind: .dateWindow,
            jid: jid,
            conversationType: .regular,
            purpose: .jump,
            nextPage: nil,
            prevPage: nil,
            ids: nil,
            start: start,
            end: end,
            max: max,
            usesServerArchiveId: false,
            coverageUpdateKind: .disjointWindow
        )
    }

    static func regularGapRepairRequestPlan(
        jid: String,
        gap: RegularChatArchiveGap,
        direction: RegularArchiveGapRepairDirection,
        pageSize: Int
    ) -> RegularChatArchiveRequestPlan {
        archiveGapRepairRequestPlan(
            jid: jid,
            conversationType: .regular,
            gap: gap,
            direction: direction,
            pageSize: pageSize
        )
    }

    static func archiveGapRepairRequestPlan(
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        gap: RegularChatArchiveGap,
        direction: RegularArchiveGapRepairDirection,
        pageSize: Int
    ) -> RegularChatArchiveRequestPlan {
        let pageSize = regularArchivePageSize(requested: pageSize)
        switch direction {
        case .older:
            let cursor = gap.newerRangeOldestArchiveId
            let request = olderPageRequest(messageId: cursor, pageSize: pageSize)
            return RegularChatArchiveRequestPlan(
                kind: .gapRepair,
                jid: jid,
                conversationType: conversationType,
                purpose: .gapRepair,
                nextPage: request.nextPage,
                prevPage: request.prevPage,
                ids: nil,
                start: nil,
                end: nil,
                max: request.max,
                usesServerArchiveId: true,
                coverageUpdateKind: .gapRepairOlder(cursorArchiveId: cursor)
            )
        case .newer:
            let cursor = gap.olderRangeNewestArchiveId
            let request = newerPageRequest(messageId: cursor, pageSize: pageSize)
            return RegularChatArchiveRequestPlan(
                kind: .gapRepair,
                jid: jid,
                conversationType: conversationType,
                purpose: .gapRepair,
                nextPage: request.nextPage,
                prevPage: request.prevPage,
                ids: nil,
                start: nil,
                end: nil,
                max: request.max,
                usesServerArchiveId: true,
                coverageUpdateKind: .gapRepairNewer(cursorArchiveId: cursor)
            )
        }
    }

    static func snapshotRepairRequestPlan(
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        newestLoadedArchiveId: String?,
        pageSize: Int
    ) -> RegularChatArchiveRequestPlan {
        if let newestLoadedArchiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(newestLoadedArchiveId) {
            let request = newerPageRequest(messageId: newestLoadedArchiveId, pageSize: pageSize)
            return RegularChatArchiveRequestPlan(
                kind: .snapshotRepair,
                jid: jid,
                conversationType: conversationType,
                purpose: .snapshotRepair,
                nextPage: request.nextPage,
                prevPage: request.prevPage,
                ids: nil,
                start: nil,
                end: nil,
                max: request.max,
                usesServerArchiveId: true,
                coverageUpdateKind: .pageNewer(cursorArchiveId: newestLoadedArchiveId)
            )
        }

        let request = newestBootstrapPageRequest(pageSize: pageSize)
        return RegularChatArchiveRequestPlan(
            kind: .snapshotRepair,
            jid: jid,
            conversationType: conversationType,
            purpose: .snapshotRepair,
            nextPage: request.nextPage,
            prevPage: request.prevPage,
            ids: nil,
            start: nil,
            end: nil,
            max: request.max,
            usesServerArchiveId: false,
            coverageUpdateKind: .bootstrapNewest
        )
    }

    static func getArchiveLowerBoundForConversation(
        conversationType: ClientSynchronizationManager.ConversationType,
        requestedFrom: Date?,
        accountCreatedAt: Date?
    ) -> Date? {
        guard conversationType == .omemo,
              let accountCreatedAt = accountCreatedAt else {
            return requestedFrom
        }

        guard let requestedFrom = requestedFrom else {
            return accountCreatedAt
        }

        return requestedFrom < accountCreatedAt ? accountCreatedAt : requestedFrom
    }
    
    struct GapItem: Hashable, Equatable {
        
        let left: String
        let right: String
        let leftDate: Date
        let rightDate: Date
        
        var verbose: String {
            get {
                return "left: \(left) | right: \(right) "
            }
        }
    }
        
    struct ConversationArchiveBoundaryFingerprint: Equatable, Hashable {
        let chatExists: Bool
        let archiveStateExists: Bool
        let chatSnapshotArchiveId: String?
        let archiveSnapshotArchiveId: String?
        let archiveSnapshotMessageId: String?
        let unreadAfterId: String?
        let unreadCount: Int
    }

    struct MAMRequestItem: Equatable, Hashable {
        let jid: String?
        let taskID: String
        let isGroupchat: Bool
        let messageId: String?
        let conversationType: ClientSynchronizationManager.ConversationType
        let isContinues: Bool
        let maxDate: Date?
        let searchText: String?
        let queryId: String?
        let afterId: String?
        let nextPage: String?
        let prevPage: String?
        let max: Int
        let tags: [Tags]
        let start: Date?
        let end: Date?
        let purpose: RequestPurpose
        let coverageUpdateKind: RegularArchiveCoverageUpdateKind
        let archiveEndEligibility: Bool
        let consumerManagesArchiveEnd: Bool
        let consumerManagesHistoryCursor: Bool
        let deferCoverageCommitUntilConsumerProof: Bool
        let boundaryFingerprintAtRequestStart: ConversationArchiveBoundaryFingerprint?
    }

    private struct DeferredArchiveCommitDescriptor {
        let task: MAMRequestItem
        let state: MessageArchivePageEndState
        let first: String
        let last: String
        let count: Int
    }
    
    struct CallbackQueueItem: Equatable, Hashable {
        static func == (lhs: CallbackQueueItem, rhs: CallbackQueueItem) -> Bool {
            return lhs.elementId == rhs.elementId
        }
        
        let jid: String
        let elementId: String
        let task: MAMRequestItem
        let callback: (() -> Void)?
        let requestCallbacks: RequestCallbacks
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(elementId)
        }
    }
    
    var callbacksQueue: Set<CallbackQueueItem> = Set<CallbackQueueItem>()
    private let callbacksQueueLock = NSRecursiveLock()

    @discardableResult
    internal func upsertCallbackQueueItem(_ item: CallbackQueueItem) -> CallbackQueueItem? {
        callbacksQueueLock.lock()
        defer { callbacksQueueLock.unlock() }
        return callbacksQueue.update(with: item)
    }

    internal func firstCallbackQueueItem(where predicate: (CallbackQueueItem) -> Bool) -> CallbackQueueItem? {
        callbacksQueueLock.lock()
        defer { callbacksQueueLock.unlock() }
        return callbacksQueue.first(where: predicate)
    }

    internal func callbackQueueContains(where predicate: (CallbackQueueItem) -> Bool) -> Bool {
        callbacksQueueLock.lock()
        defer { callbacksQueueLock.unlock() }
        return callbacksQueue.contains(where: predicate)
    }

    internal func callbackQueueItems(where predicate: (CallbackQueueItem) -> Bool = { _ in true }) -> [CallbackQueueItem] {
        callbacksQueueLock.lock()
        defer { callbacksQueueLock.unlock() }
        return callbacksQueue.filter(predicate)
    }

    internal func removeCallbackQueueItem(_ item: CallbackQueueItem) {
        callbacksQueueLock.lock()
        defer { callbacksQueueLock.unlock() }
        callbacksQueue.remove(item)
    }

    @discardableResult
    internal func drainCallbackQueueItems() -> [CallbackQueueItem] {
        callbacksQueueLock.lock()
        defer { callbacksQueueLock.unlock() }
        let items = Array(callbacksQueue)
        callbacksQueue.removeAll()
        return items
    }

    private struct FallbackEndPageCallbackKey: Hashable {
        let owner: String
        let queryId: String
    }

    private static let fallbackEndPageCallbacksLock = NSLock()
    private static var fallbackEndPageCallbacksByKey: [FallbackEndPageCallbackKey: RequestCallbacks] = [:]
    
//    var delegate: MessageArchiveManagerDelegate? = nil
    var backgroundTaskDelegate: XMPPBackgroundTaskDelegate? = nil
    
    var interactiveQueue: SynchronizedArray<String> = SynchronizedArray<String>()
    
    internal var version: String? = nil
    public var isInitialArchiveRequested: Bool = false
    
    public var allowHistoryFixTask: Bool = false
    public var isExtendedArchiveAvailable: Bool = false
    
    public var continuesTaskID: String? = nil
    
    internal let pageSize: Int = ChatHistoryPagingConfiguration.pageSize
    
    internal var searchResultsQueries: Set<String> = Set()
    internal var searchContinuationDelay: TimeInterval = 2
    /// Upper bound for background query-scoped Realm persistence. Interactive
    /// chat bootstrap owns its own watchdog; this protects autonomous pumps.
    internal var archivePersistenceTerminalTimeout: TimeInterval = 15

    private struct PendingSearchContinuation {
        let id: UUID
        let workItem: DispatchWorkItem
    }

    private let searchArchiveStateLock = NSRecursiveLock()
    private var searchArchiveSessionsByQueryId: [String: ChatSearchArchiveSession] = [:]
    private var searchArchiveCallbacksByQueryId: [String: RequestCallbacks] = [:]
    private var pendingSearchContinuationsByQueryId: [String: PendingSearchContinuation] = [:]
    
    open var temporaryMessageReceiverDelegate: TemporaryMessageReceiverProtocol? = nil
    private var persistedMessageCountsByQueryId: [String: Int] = [:]
    private final class RegularArchiveInFlightEntry {
        let queryId: String
        var requestCallbacks: [RequestCallbacks] = []
        var completionCallbacks: [() -> Void] = []
        let priority: RegularChatArchiveRequestPriority

        init(queryId: String, priority: RegularChatArchiveRequestPriority) {
            self.queryId = queryId
            self.priority = priority
        }
    }
    private var regularArchiveInFlightByKey: [RegularChatArchiveRequestKey: RegularArchiveInFlightEntry] = [:]
    private var regularArchiveRequestKeyByQueryId: [String: RegularChatArchiveRequestKey] = [:]
    private let deferredArchiveCommitLock = NSLock()
    private var deferredArchiveCommitsByQueryId: [String: DeferredArchiveCommitDescriptor] = [:]
    private var deferredArchiveCommitOrder: [String] = []
    private let maximumDeferredArchiveCommitCount = 128
    private let snapshotRepairPumpLock = NSLock()
    private var pendingSnapshotRepairTargets: [SnapshotRepairTarget] = []
    private var scheduledSnapshotRepairTargets: Set<SnapshotRepairTarget> = []
    private var activeSnapshotRepairTarget: SnapshotRepairTarget?
    private var snapshotRepairPriorityByTarget: [SnapshotRepairTarget: AccountXMPPTaskScheduler.Priority] = [:]
    private var snapshotRepairFollowUpCountByTarget: [SnapshotRepairTarget: Int] = [:]
    private var snapshotRepairEnqueuedAtByTarget: [SnapshotRepairTarget: Date] = [:]
    private let regularIdleBackfillTriggerLock = NSLock()
    private var regularIdleBackfillTriggerState = RegularIdleBackfillTriggerState()
    private let archiveRequestLifecycleLock = NSRecursiveLock()
    private var archiveRequestLifecycleGeneration: UInt64 = 0
    private let archiveQueryPurposeLock = NSLock()
    private var archiveQueryPurposeByQueryId: [String: RequestPurpose] = [:]
    private struct PendingArchiveFailureTransaction {
        let event: MessageArchiveRequestFailureEvent
        var terminalWaiters: [() -> Void]
    }
    private final class PendingArchiveFailureCallGroup {
        private final class Acknowledgement {
            private let lock = NSLock()
            private var didAcknowledge = false
            private let body: () -> Void

            init(_ body: @escaping () -> Void) {
                self.body = body
            }

            func acknowledge() {
                lock.lock()
                guard !didAcknowledge else {
                    lock.unlock()
                    return
                }
                didAcknowledge = true
                lock.unlock()
                body()
            }
        }

        private let lock = NSLock()
        private var remaining = 1
        private var didComplete = false
        private let completion: () -> Void

        init(completion: @escaping () -> Void) {
            self.completion = completion
        }

        func enter() -> () -> Void {
            lock.lock()
            remaining += 1
            lock.unlock()

            let acknowledgement = Acknowledgement {
                self.leave()
            }
            return acknowledgement.acknowledge
        }

        func finishRegistration() {
            leave()
        }

        private func leave() {
            let shouldComplete: Bool
            lock.lock()
            remaining = max(0, remaining - 1)
            shouldComplete = remaining == 0 && !didComplete
            if shouldComplete {
                didComplete = true
            }
            lock.unlock()
            if shouldComplete {
                completion()
            }
        }
    }
    private let pendingArchiveFailureLock = NSLock()
    private var pendingArchiveFailureTransactionsByQueryId: [String: PendingArchiveFailureTransaction] = [:]
    typealias PendingArchiveFailureFinalizationDispatcher = (@escaping () -> Void) -> Void
    var pendingArchiveFailureFinalizationDispatcher: PendingArchiveFailureFinalizationDispatcher = { work in
        work()
    }
    var snapshotRepairEnqueueObserver: ((SnapshotRepairTarget, AccountXMPPTaskScheduler.Priority, String) -> Void)?
    
    override init(withOwner owner: String) {
        self.isInitialArchiveRequested = SettingManager.shared.getKey(for: owner, scope: .messageArchive, key: "initial") == nil
        super.init(withOwner: owner)
    }
    
    private func completeCallback(_ callback: (() -> Void)?) {
        DispatchQueue.main.async {
            callback?()
        }
    }

    internal func hasActiveSearchArchiveSession(queryId: String) -> Bool {
        searchArchiveStateLock.lock()
        defer { searchArchiveStateLock.unlock() }
        return searchArchiveSessionsByQueryId[queryId]?.isActive == true
    }

    internal func hasPendingSearchContinuation(queryId: String) -> Bool {
        searchArchiveStateLock.lock()
        defer { searchArchiveStateLock.unlock() }
        return pendingSearchContinuationsByQueryId[queryId] != nil
    }

    @discardableResult
    internal func requestPendingSearchContinuation(queryId: String) -> Bool {
        searchArchiveStateLock.lock()
        guard let continuation = pendingSearchContinuationsByQueryId[queryId],
              searchArchiveSessionsByQueryId[queryId]?.isActive == true else {
            searchArchiveStateLock.unlock()
            return false
        }
        searchArchiveStateLock.unlock()
        DispatchQueue.global().async(execute: continuation.workItem)
        return true
    }

    private func registerSearchArchiveSession(
        queryId: String,
        generation: UInt64,
        configuration: ChatSearchArchiveSession.Configuration,
        callbacks: RequestCallbacks
    ) {
        searchArchiveStateLock.lock()
        defer { searchArchiveStateLock.unlock() }
        pendingSearchContinuationsByQueryId.removeValue(forKey: queryId)?.workItem.cancel()
        searchArchiveSessionsByQueryId[queryId] = ChatSearchArchiveSession(
            generation: generation,
            queryId: queryId,
            configuration: configuration
        )
        searchArchiveCallbacksByQueryId[queryId] = callbacks
    }

    private func searchArchiveCallbacks(queryId: String) -> RequestCallbacks? {
        searchArchiveStateLock.lock()
        defer { searchArchiveStateLock.unlock() }
        return searchArchiveCallbacksByQueryId[queryId]
    }

    private func acceptSearchArchiveResult(
        queryId: String,
        id: ChatSearchResult.ID,
        date: Date
    ) -> Bool? {
        searchArchiveStateLock.lock()
        defer { searchArchiveStateLock.unlock() }
        guard var session = searchArchiveSessionsByQueryId[queryId] else {
            return nil
        }
        let accepted = session.accept(
            result: .init(id: id, date: date),
            generation: session.generation,
            queryId: queryId
        )
        searchArchiveSessionsByQueryId[queryId] = session
        return accepted
    }

    private func notifySearchArchiveTerminal(
        callbacks: RequestCallbacks,
        queryId: String,
        terminal: ChatSearchArchiveSession.Terminal,
        failureEvent: MessageArchiveRequestFailureEvent? = nil
    ) {
        DispatchQueue.main.async {
            if let failureEvent {
                callbacks.onFailure?(failureEvent)
            }
            callbacks.onSearchTerminal?(queryId, terminal)
        }
    }

    @discardableResult
    private func failSearchArchiveSession(
        queryId: String,
        reason: ChatSearchArchiveSession.FailureReason,
        event: MessageArchiveRequestFailureEvent
    ) -> Bool {
        searchArchiveStateLock.lock()
        guard var session = searchArchiveSessionsByQueryId[queryId],
              session.isActive else {
            searchArchiveStateLock.unlock()
            return false
        }
        let callbacks = searchArchiveCallbacksByQueryId[queryId] ?? .none
        let terminal = session.fail(reason)
        searchArchiveSessionsByQueryId[queryId] = session
        searchArchiveStateLock.unlock()
        notifySearchArchiveTerminal(
            callbacks: callbacks,
            queryId: queryId,
            terminal: terminal,
            failureEvent: event
        )
        return true
    }

    private static func searchFailureReason(
        for event: MessageArchiveRequestFailureEvent
    ) -> ChatSearchArchiveSession.FailureReason {
        switch event.reason {
        case .timeout:
            return .timeout(description: event.errorDescription)
        case .uiActionDisconnect:
            return .transport(description: event.errorDescription)
        case .requestStartFailed:
            return .requestStart(description: event.errorDescription)
        case .serverError:
            return .server(description: event.errorDescription)
        case .malformedResponse:
            return .malformedResponse(description: event.errorDescription)
        }
    }

    private func cleanupSearchArchiveState(queryId: String) {
        searchArchiveStateLock.lock()
        pendingSearchContinuationsByQueryId.removeValue(forKey: queryId)?.workItem.cancel()
        searchArchiveSessionsByQueryId.removeValue(forKey: queryId)
        searchArchiveCallbacksByQueryId.removeValue(forKey: queryId)
        searchArchiveStateLock.unlock()
        searchResultsQueries.remove(queryId)
    }

    @discardableResult
    public func cancelSearch(queryId: String) -> Bool {
        searchArchiveStateLock.lock()
        guard var session = searchArchiveSessionsByQueryId[queryId],
              session.isActive else {
            searchArchiveStateLock.unlock()
            return false
        }
        let callbacks = searchArchiveCallbacksByQueryId[queryId] ?? .none
        let terminal = session.cancel()
        searchArchiveSessionsByQueryId[queryId] = session
        pendingSearchContinuationsByQueryId.removeValue(forKey: queryId)?.workItem.cancel()
        searchArchiveStateLock.unlock()

        if let item = firstCallbackQueueItem(where: { $0.elementId == queryId }) {
            removeCallbackQueueItem(item)
        }
        queryIds.remove(queryId)
        persistedMessageCountsByQueryId.removeValue(forKey: queryId)
        unregisterFallbackEndPageCallbacks(queryId: queryId)
        cleanupSearchArchiveState(queryId: queryId)
        notifySearchArchiveTerminal(
            callbacks: callbacks,
            queryId: queryId,
            terminal: terminal
        )
        return true
    }

    private static func registerFallbackEndPageCallbacks(owner: String, queryId: String, callbacks: RequestCallbacks) {
        guard owner.isNotEmpty,
              queryId.isNotEmpty,
              callbacks.onEndPage != nil else {
            return
        }

        fallbackEndPageCallbacksLock.lock()
        fallbackEndPageCallbacksByKey[FallbackEndPageCallbackKey(owner: owner, queryId: queryId)] = callbacks
        fallbackEndPageCallbacksLock.unlock()
    }

    private static func takeFallbackEndPageCallbacks(owner: String, queryId: String) -> RequestCallbacks? {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return nil
        }

        fallbackEndPageCallbacksLock.lock()
        let callbacks = fallbackEndPageCallbacksByKey.removeValue(
            forKey: FallbackEndPageCallbackKey(owner: owner, queryId: queryId)
        )
        fallbackEndPageCallbacksLock.unlock()
        return callbacks
    }

    private static func unregisterFallbackEndPageCallbacks(owner: String, queryId: String) {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return
        }

        fallbackEndPageCallbacksLock.lock()
        fallbackEndPageCallbacksByKey.removeValue(
            forKey: FallbackEndPageCallbackKey(owner: owner, queryId: queryId)
        )
        fallbackEndPageCallbacksLock.unlock()
    }

    private static func hasFallbackEndPageCallback(owner: String, queryId: String) -> Bool {
        guard owner.isNotEmpty,
              queryId.isNotEmpty else {
            return false
        }

        fallbackEndPageCallbacksLock.lock()
        let hasCallback = fallbackEndPageCallbacksByKey[
            FallbackEndPageCallbackKey(owner: owner, queryId: queryId)
        ] != nil
        fallbackEndPageCallbacksLock.unlock()
        return hasCallback
    }

    @discardableResult
    private static func notifyFallbackEndPageIfNeeded(
        owner: String,
        queryId: String,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int,
        streamKind: MessageArchiveEndPageEvent.StreamKind = .unknown
    ) -> Bool {
        let dispatcherDelivered = MessageArchiveEndPageDispatcher.publish(
            MessageArchiveEndPageEvent(
                owner: owner,
                queryId: queryId,
                state: state,
                first: first,
                last: last,
                count: count,
                streamKind: streamKind,
                source: .fallbackCallback
            )
        )

        if let callbacks = takeFallbackEndPageCallbacks(owner: owner, queryId: queryId) {
            let enqueuedAt = Date()
            ChatArchiveDebugTrace.log("mamFallbackCallbackEnqueue", [
                ("owner", owner),
                ("queryId", queryId),
                ("streamKind", streamKind.rawValue),
                ("count", count)
            ])
            DispatchQueue.main.async {
                ChatArchiveDebugTrace.log("mamFallbackCallbackStart", [
                    ("owner", owner),
                    ("queryId", queryId),
                    ("waitMs", ChatArchiveDebugTrace.milliseconds(since: enqueuedAt))
                ])
                let startedAt = Date()
                callbacks.onEndPage?(queryId, state, first, last, count)
                ChatArchiveDebugTrace.log("mamFallbackCallbackFinish", [
                    ("owner", owner),
                    ("queryId", queryId),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt))
                ])
            }
            return true
        }
        return dispatcherDelivered
    }

    private func unregisterFallbackEndPageCallbacks(queryId: String) {
        Self.unregisterFallbackEndPageCallbacks(owner: self.owner, queryId: queryId)
    }

    private func notifyDidReceiveEndPage(
        _ callbacks: RequestCallbacks,
        queryId: String,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int,
        streamKind: MessageArchiveEndPageEvent.StreamKind = .unknown
    ) {
        self.unregisterFallbackEndPageCallbacks(queryId: queryId)
        self.publishEndPageEvent(
            queryId: queryId,
            state: state,
            first: first,
            last: last,
            count: count,
            streamKind: streamKind,
            source: .localCallback
        )
        let enqueuedAt = Date()
        ChatArchiveDebugTrace.log("mamCallbackEnqueue", [
            ("owner", self.owner),
            ("queryId", queryId),
            ("streamKind", streamKind.rawValue),
            ("count", count),
            ("statePersisted", state.persistedMessageCount),
            ("queryExhausted", state.queryExhausted)
        ])
        DispatchQueue.main.async {
            ChatArchiveDebugTrace.log("mamCallbackStart", [
                ("owner", self.owner),
                ("queryId", queryId),
                ("waitMs", ChatArchiveDebugTrace.milliseconds(since: enqueuedAt))
            ])
            let startedAt = Date()
            callbacks.onEndPage?(queryId, state, first, last, count)
            self.temporaryMessageReceiverDelegate?.didReceiveEndPage(queryId: queryId, state: state, first: first, last: last, count: count)
            ChatArchiveDebugTrace.log("mamCallbackFinish", [
                ("owner", self.owner),
                ("queryId", queryId),
                ("durationMs", ChatArchiveDebugTrace.milliseconds(since: startedAt))
            ])
        }
    }

    private func notifyDidReceiveMessage(_ item: MessageStorageItem, queryId: String, callbacks: RequestCallbacks) {
        self.persistedMessageCountsByQueryId[queryId, default: 0] += 1
        DispatchQueue.main.async {
            callbacks.onMessage?(item, queryId)
            self.temporaryMessageReceiverDelegate?.didReceiveMessage(item, queryId: queryId)
        }
    }

    internal func shouldPersistArchiveQueryId(_ queryId: String?) -> Bool {
        guard let queryId,
              queryId.isNotEmpty else {
            return false
        }
        archiveQueryPurposeLock.lock()
        defer { archiveQueryPurposeLock.unlock() }
        return archiveQueryPurposeByQueryId[queryId]?.isArchiveHistoryProducing ?? false
    }

    internal func pendingArchiveRequestQueryIds(archiveProducingOnly: Bool = true) -> [String] {
        self.callbackQueueItems { item in
            !archiveProducingOnly || item.task.purpose.isArchiveHistoryProducing
        }
            .map(\.elementId)
            .sorted()
    }

    @discardableResult
    internal func publishPendingArchiveRequestFailures(
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        reason: MessageArchiveRequestFailureReason,
        errorDescription: String?,
        completion: (() -> Void)? = nil
    ) -> [MessageArchiveRequestFailureEvent] {
        let pendingItems = self.callbackQueueItems {
            $0.task.purpose.isArchiveHistoryProducing ||
                $0.task.purpose == .search ||
                $0.task.purpose == .timestampLookup
        }
            .sorted { $0.elementId < $1.elementId }
        let pendingQueryCount = pendingItems.count

        guard pendingQueryCount > 0 else {
            ChatArchiveDebugTrace.log("mamPendingRequestFailureNoop", [
                ("owner", self.owner),
                ("streamKind", streamKind.rawValue),
                ("reason", reason.rawValue)
            ])
            completion?()
            return []
        }

        let events = pendingItems.map { item in
            MessageArchiveRequestFailureEvent(
                owner: self.owner,
                queryId: item.elementId,
                streamKind: streamKind,
                reason: reason,
                errorDescription: errorDescription,
                pendingQueryCount: pendingQueryCount
            )
        }

        let terminalGroup = PendingArchiveFailureCallGroup(
            completion: completion ?? {}
        )
        zip(pendingItems, events).forEach { item, event in
            if item.task.purpose == .search {
                _ = self.failSearchArchiveSession(
                    queryId: event.queryId,
                    reason: Self.searchFailureReason(for: event),
                    event: event
                )
            } else if item.task.purpose == .timestampLookup {
                self.notifyDidFailRequest(item.requestCallbacks, event: event)
            } else if item.task.purpose.isArchiveHistoryProducing {
                self.beginPendingArchiveFailure(
                    item: item,
                    event: event,
                    terminal: terminalGroup.enter()
                )
                return
            }
            self.removePendingArchiveRequestAfterFailure(item)
            self.publishPendingArchiveFailureEvent(event)
        }

        ChatArchiveDebugTrace.log("mamPendingRequestFailurePublish", [
            ("owner", self.owner),
            ("streamKind", streamKind.rawValue),
            ("reason", reason.rawValue),
            ("pendingQueryCount", pendingQueryCount),
            ("queryIds", events.map(\.queryId).joined(separator: ","))
        ])
        terminalGroup.finishRegistration()
        return events
    }

    private func beginPendingArchiveFailure(
        item: CallbackQueueItem,
        event: MessageArchiveRequestFailureEvent,
        terminal: @escaping () -> Void
    ) {
        let shouldStartPreparation: Bool
        pendingArchiveFailureLock.lock()
        if var transaction = pendingArchiveFailureTransactionsByQueryId[event.queryId] {
            transaction.terminalWaiters.append(terminal)
            pendingArchiveFailureTransactionsByQueryId[event.queryId] = transaction
            shouldStartPreparation = false
        } else {
            pendingArchiveFailureTransactionsByQueryId[event.queryId] = PendingArchiveFailureTransaction(
                event: event,
                terminalWaiters: [terminal]
            )
            shouldStartPreparation = true
        }
        pendingArchiveFailureLock.unlock()

        guard shouldStartPreparation else {
            return
        }

        let preparationStartedAt = Date()
        let finalizationDispatcher = pendingArchiveFailureFinalizationDispatcher
        let prepared = MessageArchiveRequestFailurePreparationDispatcher.prepare(event) { [self] in
            finalizationDispatcher { [self] in
                ChatArchiveDebugTrace.log("mamPendingFailurePersistenceTerminal", [
                    ("owner", owner),
                    ("queryId", event.queryId),
                    ("durationMs", ChatArchiveDebugTrace.milliseconds(since: preparationStartedAt))
                ])
                finalizePendingArchiveFailure(queryId: event.queryId, fallbackItem: item)
            }
        }
        ChatArchiveDebugTrace.log("mamPendingFailurePersistencePrepare", [
            ("owner", owner),
            ("queryId", event.queryId),
            ("hasPreparation", prepared)
        ])
    }

    private func hasPendingArchiveFailure(queryId: String) -> Bool {
        guard queryId.isNotEmpty else {
            return false
        }
        pendingArchiveFailureLock.lock()
        let isPending = pendingArchiveFailureTransactionsByQueryId[queryId] != nil
        pendingArchiveFailureLock.unlock()
        return isPending
    }

    private func finalizePendingArchiveFailure(
        queryId: String,
        fallbackItem: CallbackQueueItem
    ) {
        pendingArchiveFailureLock.lock()
        guard let transaction = pendingArchiveFailureTransactionsByQueryId[queryId] else {
            pendingArchiveFailureLock.unlock()
            return
        }
        pendingArchiveFailureLock.unlock()

        if let currentItem = firstCallbackQueueItem(where: { $0.elementId == queryId }) {
            removePendingArchiveRequestAfterFailure(currentItem)
        } else {
            removeArchiveRequestStateAfterFailure(queryId: fallbackItem.elementId)
            if let taskQueryId = fallbackItem.task.queryId,
               taskQueryId != fallbackItem.elementId {
                removeArchiveRequestStateAfterFailure(queryId: taskQueryId)
            }
        }
        publishPendingArchiveFailureEvent(transaction.event)

        pendingArchiveFailureLock.lock()
        let waiters = pendingArchiveFailureTransactionsByQueryId
            .removeValue(forKey: queryId)?
            .terminalWaiters ?? []
        pendingArchiveFailureLock.unlock()
        waiters.forEach { $0() }
    }

    private func publishPendingArchiveFailureEvent(
        _ event: MessageArchiveRequestFailureEvent
    ) {
        let delivered = MessageArchiveRequestFailureDispatcher.publish(event)
        if !delivered {
            ChatArchiveDebugTrace.log("mamPendingRequestFailureDropNoHandler", [
                ("owner", self.owner),
                ("queryId", event.queryId),
                ("streamKind", event.streamKind.rawValue),
                ("reason", event.reason.rawValue),
                ("pendingQueryCount", event.pendingQueryCount)
            ])
        }
    }

    private func removePendingArchiveRequestAfterFailure(_ item: CallbackQueueItem) {
        self.completeCallback(item.callback)
        self.removeCallbackQueueItem(item)
        self.removeArchiveRequestStateAfterFailure(queryId: item.elementId)
        if let taskQueryId = item.task.queryId,
           taskQueryId != item.elementId {
            self.removeArchiveRequestStateAfterFailure(queryId: taskQueryId)
        }
    }

    private func notifyDidFailRequest(
        _ callbacks: RequestCallbacks,
        event: MessageArchiveRequestFailureEvent
    ) {
        DispatchQueue.main.async {
            callbacks.onFailure?(event)
        }
    }

    @discardableResult
    internal func cancelPendingArchiveRequest(queryId: String) -> Bool {
        guard queryId.isNotEmpty else {
            return false
        }

        if let item = self.firstCallbackQueueItem(where: { $0.elementId == queryId }) {
            self.removePendingArchiveRequestAfterFailure(item)
            return true
        }

        let hadState = self.queryIds.contains(queryId)
            || self.regularArchiveRequestKeyByQueryId[queryId] != nil
            || self.shouldPersistArchiveQueryId(queryId)
        guard hadState else {
            return false
        }
        self.removeArchiveRequestStateAfterFailure(queryId: queryId)
        return true
    }

    private func removeArchiveRequestStateAfterFailure(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }
        self.queryIds.remove(queryId)
        self.persistedMessageCountsByQueryId.removeValue(forKey: queryId)
        self.searchResultsQueries.remove(queryId)
        self.cleanupSearchArchiveState(queryId: queryId)
        self.unregisterArchiveQueryId(queryId)
        self.unregisterFallbackEndPageCallbacks(queryId: queryId)

        if let key = self.regularArchiveRequestKeyByQueryId.removeValue(forKey: queryId) {
            self.regularArchiveInFlightByKey.removeValue(forKey: key)
        }
    }

    private func registerArchiveQueryId(_ queryId: String, purpose: RequestPurpose) {
        guard purpose.isArchiveHistoryProducing,
              queryId.isNotEmpty else {
            return
        }
        archiveQueryPurposeLock.lock()
        archiveQueryPurposeByQueryId[queryId] = purpose
        archiveQueryPurposeLock.unlock()
    }

    private func unregisterArchiveQueryId(_ queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }
        archiveQueryPurposeLock.lock()
        archiveQueryPurposeByQueryId.removeValue(forKey: queryId)
        archiveQueryPurposeLock.unlock()
    }

    private func clearArchiveQueryPurposeRegistry() {
        archiveQueryPurposeLock.lock()
        archiveQueryPurposeByQueryId.removeAll()
        archiveQueryPurposeLock.unlock()
    }

    private func accountCreatedAtForArchiveLimit(conversationType: ClientSynchronizationManager.ConversationType) -> Date? {
        guard conversationType == .omemo else {
            return nil
        }

        do {
            let realm = try WRealm.safe()
            return realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner)?.createdAt
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    private func archiveDateConstraint(
        conversationType: ClientSynchronizationManager.ConversationType,
        requestedStart: Date?,
        requestedEnd: Date?
    ) -> ArchiveDateConstraint {
        let accountCreatedAt = self.accountCreatedAtForArchiveLimit(conversationType: conversationType)
        let effectiveStart = Self.getArchiveLowerBoundForConversation(
            conversationType: conversationType,
            requestedFrom: requestedStart,
            accountCreatedAt: accountCreatedAt
        )
        let shouldSkipRequest: Bool
        if conversationType == .omemo,
           let accountCreatedAt = accountCreatedAt,
           let requestedEnd = requestedEnd {
            shouldSkipRequest = requestedEnd < accountCreatedAt
        } else {
            shouldSkipRequest = false
        }

        return ArchiveDateConstraint(
            start: effectiveStart,
            shouldSkipRequest: shouldSkipRequest
        )
    }

    private func completeSkippedArchiveRequest(
        queryId: String,
        before: String?,
        callback: (() -> Void)?,
        requestCallbacks: RequestCallbacks
    ) {
        let pageEndState = MessageArchivePageEndState(
            queryExhausted: true,
            archiveEnded: true,
            persistedMessageCount: 0,
            requestCursorId: before
        )
        self.completeCallback(callback)
        self.notifyDidReceiveEndPage(
            requestCallbacks,
            queryId: queryId,
            state: pageEndState,
            first: "",
            last: "",
            count: 0
        )
    }

    private func makePageEndState(
        for task: MAMRequestItem,
        queryId: String,
        queryExhausted: Bool
    ) -> MessageArchivePageEndState {
        let persistedMessageCount = self.persistedMessageCountsByQueryId.removeValue(forKey: queryId) ?? 0
        return MessageArchivePageEndState(
            queryExhausted: queryExhausted,
            archiveEnded: queryExhausted && task.archiveEndEligibility,
            persistedMessageCount: persistedMessageCount,
            requestCursorId: task.messageId
        )
    }

    private func handleSearchArchiveFinal(
        _ stream: XMPPStream,
        item: CallbackQueueItem,
        responseQueryId: String,
        complete: Bool,
        first: String,
        last: String,
        resultCount: Int,
        streamKind: MessageArchiveEndPageEvent.StreamKind
    ) -> Bool {
        let queryId = item.task.queryId ?? item.elementId
        guard responseQueryId == queryId else {
            let event = MessageArchiveRequestFailureEvent(
                owner: owner,
                queryId: queryId,
                streamKind: streamKind,
                reason: .malformedResponse,
                errorDescription: "MAM search final queryid does not match the active request",
                pendingQueryCount: 1
            )
            _ = failSearchArchiveSession(
                queryId: queryId,
                reason: Self.searchFailureReason(for: event),
                event: event
            )
            removePendingArchiveRequestAfterFailure(item)
            _ = MessageArchiveRequestFailureDispatcher.publish(event)
            return true
        }

        let persistedState = makePageEndState(
            for: item.task,
            queryId: queryId,
            queryExhausted: complete || resultCount == 0
        )
        searchArchiveStateLock.lock()
        guard var session = searchArchiveSessionsByQueryId[queryId],
              session.receiveFinal(
                  generation: session.generation,
                  queryId: queryId,
                  complete: complete,
                  first: first,
                  last: last,
                  serverResultCount: resultCount
              ),
              let action = session.commitPersistedPage(
                  generation: session.generation,
                  queryId: queryId,
                  persistedMessageCount: persistedState.persistedMessageCount
              ) else {
            searchArchiveStateLock.unlock()
            removeCallbackQueueItem(item)
            queryIds.remove(item.elementId)
            return true
        }
        searchArchiveSessionsByQueryId[queryId] = session
        let callbacks = searchArchiveCallbacksByQueryId[queryId] ?? item.requestCallbacks
        searchArchiveStateLock.unlock()

        removeCallbackQueueItem(item)
        queryIds.remove(item.elementId)
        unregisterFallbackEndPageCallbacks(queryId: queryId)

        switch action {
        case .requestNext(let cursor):
            scheduleSearchArchiveContinuation(
                stream,
                task: item.task,
                queryId: queryId,
                cursor: cursor
            )
            callbacks.onSearchContinuationAvailable?(queryId, cursor)
        case .terminal(let terminal):
            notifySearchArchiveTerminal(
                callbacks: callbacks,
                queryId: queryId,
                terminal: terminal
            )
            switch terminal {
            case .completed, .truncated:
                let terminalState = MessageArchivePageEndState(
                    queryExhausted: true,
                    archiveEnded: false,
                    persistedMessageCount: persistedState.persistedMessageCount,
                    requestCursorId: item.task.messageId
                )
                notifyDidReceiveEndPage(
                    callbacks,
                    queryId: queryId,
                    state: terminalState,
                    first: first,
                    last: last,
                    count: resultCount,
                    streamKind: streamKind
                )
            case .failed, .cancelled:
                break
            }
            cleanupSearchArchiveState(queryId: queryId)
        }
        return true
    }

    private func scheduleSearchArchiveContinuation(
        _ stream: XMPPStream,
        task: MAMRequestItem,
        queryId: String,
        cursor: String
    ) {
        let continuationId = UUID()
        let workItem = DispatchWorkItem { [weak self, weak stream] in
            guard let self,
                  let stream else {
                return
            }
            self.searchArchiveStateLock.lock()
            guard self.pendingSearchContinuationsByQueryId[queryId]?.id == continuationId,
                  self.searchArchiveSessionsByQueryId[queryId]?.isActive == true else {
                self.searchArchiveStateLock.unlock()
                return
            }
            self.pendingSearchContinuationsByQueryId.removeValue(forKey: queryId)
            let callbacks = self.searchArchiveCallbacksByQueryId[queryId] ?? .none
            self.searchArchiveStateLock.unlock()

            callbacks.onSearchContinuationStarted?(queryId, cursor)

            self.requestArchive(
                stream,
                jid: task.jid,
                isContinues: true,
                conversationType: task.conversationType,
                purpose: .search,
                queryId: queryId,
                searchText: task.searchText,
                flipPage: false,
                before: task.messageId,
                afterId: task.afterId,
                start: task.start,
                end: task.end,
                nextPage: cursor,
                max: task.max,
                tags: task.tags,
                callback: nil,
                requestCallbacks: callbacks
            )
        }

        searchArchiveStateLock.lock()
        pendingSearchContinuationsByQueryId.removeValue(forKey: queryId)?.workItem.cancel()
        pendingSearchContinuationsByQueryId[queryId] = PendingSearchContinuation(
            id: continuationId,
            workItem: workItem
        )
        searchArchiveStateLock.unlock()
        DispatchQueue.global().asyncAfter(
            deadline: .now() + searchContinuationDelay,
            execute: workItem
        )
    }

    private func shouldCommitOwnedArchiveEnd(
        task: MAMRequestItem,
        state: MessageArchivePageEndState,
        count: Int
    ) -> Bool {
        guard task.archiveEndEligibility,
              !task.consumerManagesArchiveEnd,
              !task.deferCoverageCommitUntilConsumerProof,
              state.archiveEnded else {
            return false
        }
        if count == 0 {
            return true
        }
        return state.persistedMessageCount > 0
    }

    private func applyOwnedConversationArchivePageResultIfNeeded(
        task: MAMRequestItem,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int
    ) {
        guard shouldCommitOwnedArchiveEnd(task: task, state: state, count: count) else {
            return
        }
        _ = applyConversationArchivePageResult(
            task: task,
            state: state,
            first: first,
            last: last,
            count: count
        )
    }

    private func canMarkArchiveEnd(
        purpose: RequestPurpose,
        searchText: String?,
        ids: [String]?,
        beforeId: String?,
        afterId: String?,
        start: Date?,
        end: Date?,
        tags: [Tags],
        withCounter: Bool
    ) -> Bool {
        guard ArchiveEndPolicy.canCommitCoverage(for: purpose),
              [.bootstrap, .pageOlder].contains(purpose) else {
            return false
        }

        // Only pure identity-based archive walks may update the chat's oldest-boundary state.
        // If requestArchive gains more MAM data-form filters in the future, they must be added here.
        return searchText == nil &&
            (ids?.isEmpty ?? true) &&
            (beforeId?.isEmpty ?? true) &&
            (afterId?.isEmpty ?? true) &&
            start == nil &&
            end == nil &&
            tags.isEmpty &&
            !withCounter
    }

    override func namespaces() -> [String] {
        return ["urn:xmpp:mam:2"]
    }
    
    override func getPrimaryNamespace() -> String {
        return namespaces().first!
    }

    private static let mamFinalNamespaces = [
        "urn:xmpp:mam:3",
        "urn:xmpp:mam:2",
        "urn:xmpp:mam:1",
        "urn:xmpp:mam:0"
    ]

    internal static func mamFinalElement(in iq: XMPPIQ) -> DDXMLElement? {
        for namespace in mamFinalNamespaces {
            if let fin = iq.element(forName: "fin", xmlns: namespace) {
                return fin
            }
        }

        guard let fin = iq.element(forName: "fin"),
              fin.xmlns()?.hasPrefix("urn:xmpp:mam:") == true else {
            return nil
        }
        return fin
    }

    internal static func isMamCompletionIQ(_ iq: XMPPIQ, owner: String?) -> Bool {
        if iq.iqType == .result,
           mamFinalElement(in: iq) != nil {
            return true
        }

        guard iq.iqType == .error,
              let elementId = iq.elementID else {
            return false
        }

        if elementId.hasPrefix("MAM") {
            return true
        }

        guard let owner else {
            return false
        }
        return MessageArchiveEndPageDispatcher.hasHandler(owner: owner, queryId: elementId) ||
            MessageArchiveRequestFailureDispatcher.hasHandler(owner: owner, queryId: elementId)
    }

    internal static func mamErrorDescription(from iq: XMPPIQ) -> String? {
        guard let error = iq.element(forName: "error") else {
            return nil
        }

        var parts: [String] = []
        if let code = error.attributeStringValue(forName: "code"),
           code.isNotEmpty {
            parts.append(code)
        }
        if let type = error.attributeStringValue(forName: "type"),
           type.isNotEmpty {
            parts.append(type)
        }
        if let condition = xmppStanzaErrorCondition(in: error) {
            parts.append(condition)
        }
        if let text = error.elements(forName: "text").first?.stringValue,
           text.isNotEmpty {
            parts.append(text)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func xmppStanzaErrorCondition(in error: DDXMLElement) -> String? {
        let knownConditions = [
            "bad-request",
            "conflict",
            "feature-not-implemented",
            "forbidden",
            "gone",
            "internal-server-error",
            "item-not-found",
            "jid-malformed",
            "not-acceptable",
            "not-allowed",
            "not-authorized",
            "policy-violation",
            "recipient-unavailable",
            "redirect",
            "registration-required",
            "remote-server-not-found",
            "remote-server-timeout",
            "resource-constraint",
            "service-unavailable",
            "subscription-required",
            "undefined-condition",
            "unexpected-request"
        ]
        return knownConditions.first {
            error.element(forName: $0, xmlns: "urn:ietf:params:xml:ns:xmpp-stanzas") != nil
        }
    }

    internal static func unroutedEndPageEvent(
        owner: String,
        iq: XMPPIQ,
        streamKind: MessageArchiveEndPageEvent.StreamKind
    ) -> MessageArchiveEndPageEvent? {
        if iq.iqType == .error,
           let elementId = iq.elementID {
            return MessageArchiveEndPageEvent(
                owner: owner,
                queryId: elementId,
                state: MessageArchivePageEndState(
                    queryExhausted: true,
                    archiveEnded: true,
                    persistedMessageCount: 0,
                    requestCursorId: nil
                ),
                first: "",
                last: "",
                count: 0,
                streamKind: streamKind,
                source: .unroutedErrorIQ
            )
        }

        guard iq.iqType == .result,
              let fin = mamFinalElement(in: iq),
              let queryId = fin.attributeStringValue(forName: "queryid"),
              let set = fin.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm") else {
            return nil
        }

        let complete = fin.attributeBoolValue(forName: "complete")
        let count = set.element(forName: "count")?.stringValueAsNSInteger() ?? 0
        return MessageArchiveEndPageEvent(
            owner: owner,
            queryId: queryId,
            state: MessageArchivePageEndState(
                queryExhausted: count == 0 || complete,
                archiveEnded: count == 0 || complete,
                persistedMessageCount: 0,
                requestCursorId: nil
            ),
            first: set.element(forName: "first")?.stringValue ?? "",
            last: set.element(forName: "last")?.stringValue ?? "",
            count: count,
            streamKind: streamKind,
            source: .unroutedFinalIQ
        )
    }

    private static func streamKind(for stream: XMPPStream) -> MessageArchiveEndPageEvent.StreamKind {
        guard let resource = stream.myJID?.resource else {
            return .unknown
        }
        if resource.contains("_ui_upgrade_task") {
            return .uiAction
        }
        return .primary
    }

    @discardableResult
    private func publishEndPageEvent(
        queryId: String,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int,
        streamKind: MessageArchiveEndPageEvent.StreamKind,
        source: MessageArchiveEndPageEvent.Source
    ) -> Bool {
        MessageArchiveEndPageDispatcher.publish(
            MessageArchiveEndPageEvent(
                owner: self.owner,
                queryId: queryId,
                state: state,
                first: first,
                last: last,
                count: count,
                streamKind: streamKind,
                source: source
            )
        )
    }
    
    func makeInitialMessageVisible(jid: String, conversationType: ClientSynchronizationManager.ConversationType, queryId: String) throws {
        if !shouldPersistArchiveQueryId(queryId) {
            return
        }
        let realm = try WRealm.safe()
        if let instance = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: self.owner,
                conversationType: conversationType
            )
        ) {
            try realm.write {
                instance.isAllHistoryLoaded = true
            }
        }
    }
    
    func read(_ stream: XMPPStream, withIQ iq: XMPPIQ) -> Bool {
        let streamKind = Self.streamKind(for: stream)
        if let elementId = iq.elementID,
           hasPendingArchiveFailure(queryId: elementId) {
            ChatArchiveDebugTrace.log("mamTerminalIQIgnoredDuringFailurePreparation", [
                ("owner", owner),
                ("queryId", elementId),
                ("streamKind", streamKind.rawValue),
                ("iqType", iq.type ?? "unknown")
            ])
            return true
        }
        if iq.iqType == .error,
           let elementId = iq.elementID {
            let localCallbackRegistered = self.callbackQueueContains { $0.elementId == elementId }
            let dispatcherRegistered = MessageArchiveEndPageDispatcher.hasHandler(owner: self.owner, queryId: elementId)
            let fallbackRegistered = Self.hasFallbackEndPageCallback(owner: self.owner, queryId: elementId)
            let localQueryRegistered = self.queryIds.contains(elementId)
            ChatArchiveDebugTrace.log("mamErrorReceived", [
                ("owner", self.owner),
                ("queryId", elementId),
                ("elementId", elementId),
                ("streamKind", streamKind.rawValue),
                ("localCallbackRegistered", localCallbackRegistered),
                ("dispatcherRegistered", dispatcherRegistered),
                ("fallbackRegistered", fallbackRegistered),
                ("localQueryRegistered", localQueryRegistered),
                ("route", localCallbackRegistered ? "activeLocalCallback" : ((dispatcherRegistered || fallbackRegistered || localQueryRegistered) ? "fallbackOrRegistered" : "staleNoActiveContext"))
            ])
            if let item = self.firstCallbackQueueItem(where: { $0.elementId == elementId }) {
                let queryId = item.task.queryId ?? elementId
                if item.task.purpose.routesMamServerErrorAsRequestFailure {
                    let event = MessageArchiveRequestFailureEvent(
                        owner: self.owner,
                        queryId: queryId,
                        streamKind: streamKind,
                        reason: .serverError,
                        errorDescription: Self.mamErrorDescription(from: iq),
                        pendingQueryCount: 1
                    )
                    if item.task.purpose == .search {
                        _ = self.failSearchArchiveSession(
                            queryId: queryId,
                            reason: Self.searchFailureReason(for: event),
                            event: event
                        )
                    } else if item.task.purpose == .timestampLookup {
                        self.notifyDidFailRequest(item.requestCallbacks, event: event)
                    }
                    if item.task.purpose.isArchiveHistoryProducing {
                        self.beginPendingArchiveFailure(
                            item: item,
                            event: event,
                            terminal: {}
                        )
                        return true
                    }
                    self.removePendingArchiveRequestAfterFailure(item)
                    let delivered = MessageArchiveRequestFailureDispatcher.publish(event)
                    if !delivered {
                        ChatArchiveDebugTrace.log("mamErrorRequestFailureDropNoHandler", [
                            ("owner", self.owner),
                            ("queryId", queryId),
                            ("elementId", elementId),
                            ("streamKind", streamKind.rawValue),
                            ("reason", event.reason.rawValue),
                            ("error", event.errorDescription ?? "none")
                        ])
                    }
                    return true
                }
                let pageEndState = self.makePageEndState(
                    for: item.task,
                    queryId: queryId,
                    queryExhausted: true
                )
                self.completeCallback(item.callback)
                self.notifyDidReceiveEndPage(
                    item.requestCallbacks,
                    queryId: queryId,
                    state: pageEndState,
                    first: "",
                    last: "",
                    count: 0,
                    streamKind: streamKind
                )
                self.finishRegularArchiveRequest(queryId: queryId, item: item, state: nil, first: "", last: "", count: 0)
                self.removeCallbackQueueItem(item)
                self.queryIds.remove(elementId)
                return true
            }

            let pageEndState = MessageArchivePageEndState(
                queryExhausted: true,
                archiveEnded: true,
                persistedMessageCount: self.persistedMessageCountsByQueryId.removeValue(forKey: elementId) ?? 0,
                requestCursorId: nil
            )
            let fallbackDelivered = Self.notifyFallbackEndPageIfNeeded(
                owner: self.owner,
                queryId: elementId,
                state: pageEndState,
                first: "",
                last: "",
                count: 0,
                streamKind: streamKind
            )
            if fallbackDelivered || self.queryIds.contains(elementId) {
                ChatArchiveDebugTrace.log("mamOrphanErrorHandled", [
                    ("localQueryRegistered", self.queryIds.contains(elementId)),
                    ("fallbackDelivered", fallbackDelivered)
                ])
                self.unregisterArchiveQueryId(elementId)
                self.queryIds.remove(elementId)
                return true
            }
        }

        guard iq.iqType == .result,
              let elementId = iq.elementID,
              let fin = Self.mamFinalElement(in: iq),
              let queryId = fin.attributeStringValue(forName: "queryid") else {
            return false
        }
        guard let set = fin.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm") else {
            guard let item = self.firstCallbackQueueItem(where: {
                $0.elementId == elementId && $0.task.purpose == .search
            }) else {
                return false
            }
            let event = MessageArchiveRequestFailureEvent(
                owner: self.owner,
                queryId: item.task.queryId ?? queryId,
                streamKind: streamKind,
                reason: .malformedResponse,
                errorDescription: "MAM search final is missing the RSM set",
                pendingQueryCount: 1
            )
            _ = self.failSearchArchiveSession(
                queryId: event.queryId,
                reason: Self.searchFailureReason(for: event),
                event: event
            )
            self.removePendingArchiveRequestAfterFailure(item)
            _ = MessageArchiveRequestFailureDispatcher.publish(event)
            return true
        }
        let complete = fin.attributeBoolValue(forName: "complete")
        let first = set.element(forName: "first")?.stringValue ?? ""
        let last = set.element(forName: "last")?.stringValue ?? ""
        let resultCount = set.element(forName: "count")?.stringValueAsNSInteger() ?? 0
        let localCallbackRegistered = self.callbackQueueContains { $0.elementId == elementId }
        let dispatcherRegistered = MessageArchiveEndPageDispatcher.hasHandler(owner: self.owner, queryId: queryId)
        let fallbackRegistered = Self.hasFallbackEndPageCallback(owner: self.owner, queryId: queryId)
        let localQueryRegistered = self.queryIds.contains(elementId) || self.queryIds.contains(queryId)
        ChatArchiveDebugTrace.log("mamFinalReceived", [
            ("owner", self.owner),
            ("queryId", queryId),
            ("elementId", elementId),
            ("streamKind", streamKind.rawValue),
            ("localCallbackRegistered", localCallbackRegistered),
            ("dispatcherRegistered", dispatcherRegistered),
            ("fallbackRegistered", fallbackRegistered),
            ("localQueryRegistered", localQueryRegistered),
            ("route", localCallbackRegistered ? "activeLocalCallback" : ((dispatcherRegistered || fallbackRegistered || localQueryRegistered) ? "fallbackOrRegistered" : "staleNoActiveContext")),
            ("count", resultCount),
            ("complete", complete),
            ("first", first),
            ("last", last)
        ])
//        DispatchQueue.global().async {
            if let item = self.firstCallbackQueueItem(where: { $0.elementId == elementId }) {
                if item.task.purpose == .search {
                    return self.handleSearchArchiveFinal(
                        stream,
                        item: item,
                        responseQueryId: queryId,
                        complete: complete,
                        first: first,
                        last: last,
                        resultCount: resultCount,
                        streamKind: streamKind
                    )
                }
                if item.task.isContinues {
                    let nextPage = set.element(forName: "last")?.stringValue
                    do {
                        if let count = set.element(forName: "count")?.stringValueAsNSInteger() {
                            let realm: Realm?
                            if item.task.deferCoverageCommitUntilConsumerProof {
                                realm = nil
                            } else {
                                realm = try Realm()
                            }
                            let pageEndState = self.makePageEndState(
                                for: item.task,
                                queryId: queryId,
                                queryExhausted: count == 0 || complete
                            )
                            self.applyOwnedConversationArchivePageResultIfNeeded(
                                task: item.task,
                                state: pageEndState,
                                first: first,
                                last: last,
                                count: count
                            )
                            
                            if let realm,
                               let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: item.jid, owner: self.owner, conversationType: item.task.conversationType)) {
                                if count == 0 {
                                    if self.shouldCommitOwnedArchiveEnd(task: item.task, state: pageEndState, count: count) {
                                        try realm.write {
                                            instance.fullArchiveLoaded = pageEndState.archiveEnded
                                        }
                                    }
                                    self.finishRegularArchiveRequest(queryId: queryId, item: item, state: pageEndState, first: first, last: last, count: count)
                                    self.removeCallbackQueueItem(item)
                                    self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count, streamKind: streamKind)
                                    self.completeCallback(item.callback)
                                    return true
                                }
                                if complete {
//                                    try self.makeInitialMessageVisible(jid: item.jid, conversationType: item.task.conversationType, queryId: elementId)
                                    if !item.task.deferCoverageCommitUntilConsumerProof {
                                        try realm.write {
                                            if self.shouldCommitOwnedArchiveEnd(task: item.task, state: pageEndState, count: count) {
                                                instance.fullArchiveLoaded = pageEndState.archiveEnded
                                            }
                                            if !item.task.consumerManagesHistoryCursor {
                                                instance.lastLoadedMessageHistoryId = HistoryCursorPolicy.persistedOlderCursorId(
                                                    purpose: item.task.purpose,
                                                    first: first,
                                                    last: last,
                                                    current: instance.lastLoadedMessageHistoryId
                                                )
                                            }
                                        }
                                    }
                                    self.finishRegularArchiveRequest(queryId: queryId, item: item, state: pageEndState, first: first, last: last, count: count)
                                    self.removeCallbackQueueItem(item)
                                    self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count, streamKind: streamKind)
                                    self.completeCallback(item.callback)
                                    return true
                                }
                            }
                            if count == 0 {
                                self.finishRegularArchiveRequest(queryId: queryId, item: item, state: pageEndState, first: first, last: last, count: count)
                                self.removeCallbackQueueItem(item)
                                self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count, streamKind: streamKind)
                                self.completeCallback(item.callback)
                                return true
                            }
                            if complete {
                                self.finishRegularArchiveRequest(queryId: queryId, item: item, state: pageEndState, first: first, last: last, count: count)
                                self.removeCallbackQueueItem(item)
                                self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count, streamKind: streamKind)
                                self.completeCallback(item.callback)
                                return true
                            }
                            self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count, streamKind: streamKind)
                        }
                    } catch {
                        DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.continueLoadHistory(
                            stream,
                            task: item.task,
                            nextPage: nextPage,
                            requestCallbacks: item.requestCallbacks,
                            callback: item.callback
                        )
                    }
                } else {
                    self.completeCallback(item.callback)
                    if let count = set.element(forName: "count")?.stringValueAsNSInteger() {
                        do {
                            let realm: Realm?
                            if item.task.deferCoverageCommitUntilConsumerProof {
                                realm = nil
                            } else {
                                realm = try Realm()
                            }
                            let pageEndState = self.makePageEndState(
                                for: item.task,
                                queryId: queryId,
                                queryExhausted: count == 0 || complete
                            )
                            self.applyOwnedConversationArchivePageResultIfNeeded(
                                task: item.task,
                                state: pageEndState,
                                first: first,
                                last: last,
                                count: count
                            )
                            if let realm,
                               let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: item.jid, owner: self.owner, conversationType: item.task.conversationType)) {
                                if !item.task.deferCoverageCommitUntilConsumerProof {
                                    try realm.write {
                                        if self.shouldCommitOwnedArchiveEnd(task: item.task, state: pageEndState, count: count) {
                                            instance.fullArchiveLoaded = pageEndState.archiveEnded
                                        }
                                        if item.task.purpose.marksInitialArchiveLoaded {
                                            instance.isInitialArchiveLoaded = true
                                            instance.isSynced = true
                                        }
                                        if !item.task.consumerManagesHistoryCursor {
                                            instance.lastLoadedMessageHistoryId = HistoryCursorPolicy.persistedOlderCursorId(
                                                purpose: item.task.purpose,
                                                first: first,
                                                last: last,
                                                current: instance.lastLoadedMessageHistoryId
                                            )
                                        }
                                    }
                                }
                            }
                            self.finishRegularArchiveRequest(
                                queryId: queryId,
                                item: item,
                                state: pageEndState,
                                first: first,
                                last: last,
                                count: count
                            )
                            if count == 0 {
//                                try self.makeInitialMessageVisible(jid: item.jid, conversationType: item.task.conversationType, queryId: elementId)
                                self.removeCallbackQueueItem(item)
                                self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count, streamKind: streamKind)
                                return true
                            }
                            if fin.attributeBoolValue(forName: "complete") {
//                                try self.makeInitialMessageVisible(jid: item.jid, conversationType: item.task.conversationType, queryId: elementId)
                                self.removeCallbackQueueItem(item)
                                self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count, streamKind: streamKind)
                                return true
                            }
                            self.notifyDidReceiveEndPage(item.requestCallbacks, queryId: queryId, state: pageEndState, first: first, last: last, count: count, streamKind: streamKind)
//                            if try self.checkShouldLoadFullHistory(for: item.jid, conversationType: item.task.conversationType) {
//                                try self.startLoadHistory(stream, jid: item.jid, conversationType: item.task.conversationType)
//                            }
                        } catch {
                            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
                        }
                    }
                }
                self.unregisterArchiveQueryId(queryId)
                self.removeCallbackQueueItem(item)
            } else {
                let count = resultCount
                let pageEndState = MessageArchivePageEndState(
                    queryExhausted: count == 0 || complete,
                    archiveEnded: count == 0 || complete,
                    persistedMessageCount: self.persistedMessageCountsByQueryId.removeValue(forKey: queryId) ?? 0,
                    requestCursorId: nil
                )
                let fallbackDelivered = Self.notifyFallbackEndPageIfNeeded(
                    owner: self.owner,
                    queryId: queryId,
                    state: pageEndState,
                    first: first,
                    last: last,
                    count: count,
                    streamKind: streamKind
                )
                ChatArchiveDebugTrace.log("mamOrphanFinalHandled", [
                    ("localQueryRegistered", self.queryIds.contains(elementId)),
                    ("fallbackDelivered", fallbackDelivered),
                    ("count", count),
                    ("complete", complete)
                ])
                self.unregisterArchiveQueryId(queryId)
                self.queryIds.remove(elementId)
            }
//        }
        return true
    }
    
    public func getHistoryByDate(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType, start: Date? = nil, end: Date? = nil, reversed: Bool = false, callback: @escaping (() -> Void)) {
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .jump,
            queryId: "MAM untill rev=\(reversed ? "true" : "false") history: \(NanoID.new(6))",
            searchText: nil,
            flipPage: true,
            before: nil,
            beforeId: nil,
            afterId: nil,
            start: start,
            end: end,
            nextPage: reversed ? "" : nil,//end == nil ? nil : "",
            prevPage: nil,
            max: 250,
            callback: callback
        )
    }
    
    public func searchText(
        _ stream: XMPPStream,
        jid: String? = nil,
        conversationType: ClientSynchronizationManager.ConversationType,
        text: String,
        max: Int = 250,
        loadFull: Bool = true,
        queryId: String? = nil,
        pageCursor: String? = nil,
        generation: UInt64 = 0,
        maximumPageCount: Int? = 1_000,
        maximumResultCount: Int? = nil,
        requestCallbacks: RequestCallbacks = .none
    ) -> String {
        let taskId = [jid ?? "global_search", conversationType.rawValue].prp()
        if let continuesTaskID = continuesTaskID {
            if taskId != continuesTaskID {
                if let item = self.firstCallbackQueueItem(where: { $0.task.taskID == continuesTaskID }) {
                    item.callback?()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.removeCallbackQueueItem(item)
                    }
                }
            }
        }
        let queryId = queryId ?? "MAM search: \(NanoID.new(8))"
        self.registerSearchArchiveSession(
            queryId: queryId,
            generation: generation,
            configuration: .init(
                maximumPageCount: loadFull ? maximumPageCount : 1,
                maximumResultCount: maximumResultCount
            ),
            callbacks: requestCallbacks
        )
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: loadFull,
            conversationType: conversationType,
            purpose: .search,
            queryId: queryId,
            searchText: text,
            flipPage: false,
            nextPage: pageCursor ?? "",
            max: max,
            callback: nil,
            requestCallbacks: requestCallbacks
        )
        self.continuesTaskID = taskId
        return queryId
    }

    @discardableResult
    internal func requestTimestampLookup(
        _ stream: XMPPStream,
        plan: ChatSearchTimestampMAMRequestPlan,
        requestCallbacks: RequestCallbacks = .none
    ) -> Bool {
        guard plan.scope.owner == owner,
              plan.scope.jid.isNotEmpty,
              let conversationType = plan.conversationType,
              !conversationType.isEncrypted,
              [.regular, .group, .channel].contains(conversationType) else {
            return false
        }

        let callbacks = RequestCallbacks(
            onMessage: requestCallbacks.onMessage,
            onEndPage: { [weak self] queryId, state, first, last, count in
                self?.searchResultsQueries.remove(queryId)
                self?.queryIds.remove(queryId)
                self?.unregisterArchiveQueryId(queryId)
                requestCallbacks.onEndPage?(queryId, state, first, last, count)
            },
            onFailure: requestCallbacks.onFailure
        )
        searchResultsQueries.insert(plan.queryId)
        requestArchive(
            stream,
            jid: plan.scope.jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .timestampLookup,
            queryId: plan.queryId,
            flipPage: plan.flipPage,
            start: plan.start,
            end: plan.end,
            nextPage: plan.nextPage,
            max: plan.max,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            callback: nil,
            requestCallbacks: callbacks
        )
        return true
    }

    @discardableResult
    internal func cancelTimestampLookup(queryId: String) -> Bool {
        guard let item = firstCallbackQueueItem(where: {
            $0.elementId == queryId && $0.task.purpose == .timestampLookup
        }) else {
            return false
        }
        removePendingArchiveRequestAfterFailure(item)
        return true
    }
    
    public func getMedia(_ stream: XMPPStream, jid: String?, conversationType: ClientSynchronizationManager.ConversationType, media: [MessageMediaAttachmentStorageItem.Kind], after lastMessageId: String?, requestCallbacks: RequestCallbacks = .none) {
        let taskId = ["media", jid ?? "global", conversationType.rawValue].prp()
        if let continuesTaskID = continuesTaskID {
            if taskId != continuesTaskID {
                if let item = self.firstCallbackQueueItem(where: { $0.task.taskID == continuesTaskID }) {
                    item.callback?()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.removeCallbackQueueItem(item)
                    }
                }
            }
        }
        let queryId = "MAM attach: \(NanoID.new(8))"
        let tags: [Tags] = media.compactMap { return Tags(rawValue: $0.rawValue) }
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .media,
            queryId: queryId,
            flipPage: false,
            nextPage: lastMessageId,
            max: 150,
            tags: tags,
            callback: nil,
            requestCallbacks: requestCallbacks
        )
        self.searchResultsQueries.insert(queryId)
        self.continuesTaskID = taskId
    }

    private static func regularRequestKey(for plan: RegularChatArchiveRequestPlan) -> RegularChatArchiveRequestKey {
        RegularChatArchiveRequestKey(
            jid: plan.jid,
            conversationTypeRaw: plan.conversationType.rawValue,
            purpose: plan.purpose,
            nextPage: plan.nextPage,
            prevPage: plan.prevPage,
            ids: plan.ids,
            startTime: plan.start?.timeIntervalSince1970,
            endTime: plan.end?.timeIntervalSince1970,
            max: plan.max
        )
    }

    private func regularArchiveCallbacks(
        primary: RequestCallbacks,
        entry: RegularArchiveInFlightEntry
    ) -> RequestCallbacks {
        RequestCallbacks(
            onMessage: { item, queryId in
                primary.onMessage?(item, queryId)
                entry.requestCallbacks.forEach { $0.onMessage?(item, queryId) }
            },
            onEndPage: { queryId, state, first, last, count in
                primary.onEndPage?(queryId, state, first, last, count)
                entry.requestCallbacks.forEach { $0.onEndPage?(queryId, state, first, last, count) }
            },
            onFailure: { event in
                primary.onFailure?(event)
                entry.requestCallbacks.forEach { $0.onFailure?(event) }
            },
            onSearchTerminal: { queryId, terminal in
                primary.onSearchTerminal?(queryId, terminal)
                entry.requestCallbacks.forEach { $0.onSearchTerminal?(queryId, terminal) }
            },
            onSearchContinuationAvailable: { queryId, cursor in
                primary.onSearchContinuationAvailable?(queryId, cursor)
                entry.requestCallbacks.forEach {
                    $0.onSearchContinuationAvailable?(queryId, cursor)
                }
            },
            onSearchContinuationStarted: { queryId, cursor in
                primary.onSearchContinuationStarted?(queryId, cursor)
                entry.requestCallbacks.forEach {
                    $0.onSearchContinuationStarted?(queryId, cursor)
                }
            }
        )
    }

    private func regularArchiveCompletion(
        primary: (() -> Void)?,
        entry: RegularArchiveInFlightEntry
    ) -> (() -> Void) {
        return {
            primary?()
            entry.completionCallbacks.forEach { $0() }
        }
    }

    @discardableResult
    internal func startRegularArchiveRequest(
        _ stream: XMPPStream,
        plan: RegularChatArchiveRequestPlan,
        queryId: String,
        flipPage: Bool = true,
        priority: RegularChatArchiveRequestPriority = .interactive,
        joinDuplicateRequests: Bool = true,
        callback: (() -> Void)? = nil,
        requestCallbacks: RequestCallbacks = .none,
        deferCoverageCommitUntilConsumerProof: Bool = false
    ) -> String {
        let key = Self.regularRequestKey(for: plan)
        if let entry = regularArchiveInFlightByKey[key] {
            if joinDuplicateRequests {
                if requestCallbacks.onMessage != nil || requestCallbacks.onEndPage != nil {
                    entry.requestCallbacks.append(requestCallbacks)
                }
                if let callback {
                    entry.completionCallbacks.append(callback)
                }
                return entry.queryId
            }

            // An explicit query ID is a new transaction. Retire an older
            // matching request before installing the replacement so Retry
            // cannot attach to a transport that has already timed out at UI.
            _ = cancelPendingArchiveRequest(queryId: entry.queryId)
        }

        let entry = RegularArchiveInFlightEntry(queryId: queryId, priority: priority)
        regularArchiveInFlightByKey[key] = entry
        regularArchiveRequestKeyByQueryId[queryId] = key

        self.requestArchive(
            stream,
            jid: plan.jid,
            isContinues: false,
            conversationType: plan.conversationType,
            purpose: plan.purpose,
            queryId: queryId,
            ids: plan.ids,
            flipPage: flipPage,
            start: plan.start,
            end: plan.end,
            nextPage: plan.nextPage,
            prevPage: plan.prevPage,
            max: plan.max,
            coverageUpdateKind: plan.coverageUpdateKind,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            deferCoverageCommitUntilConsumerProof: deferCoverageCommitUntilConsumerProof,
            callback: regularArchiveCompletion(primary: callback, entry: entry),
            requestCallbacks: regularArchiveCallbacks(primary: requestCallbacks, entry: entry)
        )
        return queryId
    }

    private func finishRegularArchiveRequest(
        queryId: String,
        item: CallbackQueueItem,
        state: MessageArchivePageEndState?,
        first: String,
        last: String,
        count: Int
    ) {
        // A completed regular request must leave no transport registration
        // behind. Several successful-result branches return immediately after
        // this helper, so relying on the common tail of read(_:withIQ:) leaves
        // the query active forever and lets a later Retry join stale state.
        queryIds.remove(queryId)
        if let state,
           item.task.deferCoverageCommitUntilConsumerProof {
            prepareDeferredArchiveCommit(
                queryId: queryId,
                task: item.task,
                state: state,
                first: first,
                last: last,
                count: count
            )
        }
        guard let key = regularArchiveRequestKeyByQueryId.removeValue(forKey: queryId) else {
            unregisterArchiveQueryId(queryId)
            return
        }
        unregisterArchiveQueryId(queryId)

        regularArchiveInFlightByKey.removeValue(forKey: key)
        let shouldApplyCoverageHere = !item.task.deferCoverageCommitUntilConsumerProof
        if let state,
           shouldApplyCoverageHere {
            _ = applyConversationArchivePageResult(
                task: item.task,
                state: state,
                first: first,
                last: last,
                count: count
            )
        }

    }

    private func prepareDeferredArchiveCommit(
        queryId: String,
        task: MAMRequestItem,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int
    ) {
        guard queryId.isNotEmpty,
              task.deferCoverageCommitUntilConsumerProof else {
            return
        }

        let descriptor = DeferredArchiveCommitDescriptor(
            task: task,
            state: state,
            first: first,
            last: last,
            count: count
        )
        deferredArchiveCommitLock.lock()
        if deferredArchiveCommitsByQueryId[queryId] == nil {
            deferredArchiveCommitOrder.append(queryId)
        }
        deferredArchiveCommitsByQueryId[queryId] = descriptor
        while deferredArchiveCommitOrder.count > maximumDeferredArchiveCommitCount {
            let expiredQueryId = deferredArchiveCommitOrder.removeFirst()
            deferredArchiveCommitsByQueryId.removeValue(forKey: expiredQueryId)
        }
        deferredArchiveCommitLock.unlock()

        ChatArchiveDebugTrace.log(deferredArchiveTraceEvent(
            purpose: task.purpose,
            phase: .prepared
        ), [
            ("count", count)
        ])
    }

    internal func hasDeferredCommit(queryId: String) -> Bool {
        guard queryId.isNotEmpty else {
            return false
        }
        deferredArchiveCommitLock.lock()
        defer { deferredArchiveCommitLock.unlock() }
        return deferredArchiveCommitsByQueryId[queryId] != nil
    }

    internal func abortDeferredCommit(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }
        deferredArchiveCommitLock.lock()
        let removedDescriptor = deferredArchiveCommitsByQueryId.removeValue(forKey: queryId)
        if removedDescriptor != nil {
            deferredArchiveCommitOrder.removeAll { $0 == queryId }
        }
        deferredArchiveCommitLock.unlock()
        if let removedDescriptor {
            ChatArchiveDebugTrace.log(deferredArchiveTraceEvent(
                purpose: removedDescriptor.task.purpose,
                phase: .aborted
            ))
        }
    }

    @discardableResult
    internal func commitAfterPersistence(
        queryId: String,
        persistenceSummary: MessageManager.ArchivePersistenceSummary
    ) -> DeferredArchiveCommitResult {
        deferredArchiveCommitLock.lock()
        let descriptor = deferredArchiveCommitsByQueryId.removeValue(forKey: queryId)
        if descriptor != nil {
            deferredArchiveCommitOrder.removeAll { $0 == queryId }
        }
        deferredArchiveCommitLock.unlock()

        guard let descriptor else {
            return .missingDescriptor
        }

        if persistenceSummary.failed > 0 {
            let rejection = DeferredArchiveCommitRejection.persistenceFailed(
                failedRows: persistenceSummary.failed
            )
            traceDeferredArchiveCommitRejection(
                descriptor: descriptor,
                reason: rejection
            )
            return .rejected(rejection)
        }

        if descriptor.count == 0 {
            guard descriptor.state.queryExhausted || descriptor.state.archiveEnded else {
                let rejection = DeferredArchiveCommitRejection.missingPersistenceProof
                traceDeferredArchiveCommitRejection(
                    descriptor: descriptor,
                    reason: rejection
                )
                return .rejected(rejection)
            }
        } else {
            if descriptor.task.coverageUpdateKind.shouldMutateCoverage,
               (descriptor.first.isEmpty || descriptor.last.isEmpty) {
                let rejection = DeferredArchiveCommitRejection.malformedCoverageRange
                traceDeferredArchiveCommitRejection(
                    descriptor: descriptor,
                    reason: rejection
                )
                return .rejected(rejection)
            }

            guard hasPersistedConversationProof(
                descriptor: descriptor,
                persistenceSummary: persistenceSummary
            ) else {
                let rejection = DeferredArchiveCommitRejection.missingPersistenceProof
                traceDeferredArchiveCommitRejection(
                    descriptor: descriptor,
                    reason: rejection
                )
                return .rejected(rejection)
            }
        }

        let applyResult = applyConversationArchivePageResult(
            task: descriptor.task,
            state: descriptor.state,
            first: descriptor.first,
            last: descriptor.last,
            count: descriptor.count
        )
        guard applyResult.didApply else {
            let rejection = DeferredArchiveCommitRejection.storageFailure
            traceDeferredArchiveCommitRejection(
                descriptor: descriptor,
                reason: rejection
            )
            return .rejected(rejection)
        }

        if applyResult.boundaryChanged || conversationRequiresFollowUpRepair(task: descriptor.task) {
            ChatArchiveDebugTrace.log(deferredArchiveTraceEvent(
                purpose: descriptor.task.purpose,
                phase: .committedNeedsRepair
            ), [
                ("resultCount", descriptor.count),
                ("persistedRows", persistenceSummary.persistedRows),
                ("failedRows", persistenceSummary.failed)
            ])
            return .committedNeedsFollowUpRepair
        }

        ChatArchiveDebugTrace.log(deferredArchiveTraceEvent(
            purpose: descriptor.task.purpose,
            phase: .committed
        ), [
            ("resultCount", descriptor.count),
            ("persistedRows", persistenceSummary.persistedRows),
            ("failedRows", persistenceSummary.failed)
        ])
        return .committed
    }

    private func conversationRequiresFollowUpRepair(task: MAMRequestItem) -> Bool {
        guard task.purpose == .bootstrap || task.purpose == .snapshotRepair,
              task.conversationType.supportsSnapshotArchiveRepair,
              let jid = task.jid,
              jid.isNotEmpty else {
            return false
        }

        do {
            let realm = try WRealm.safe()
            let primary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: self.owner,
                conversationType: task.conversationType
            )
            return realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: primary
            )?.isSynced != true
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
            return true
        }
    }

    private func hasPersistedConversationProof(
        descriptor: DeferredArchiveCommitDescriptor,
        persistenceSummary: MessageManager.ArchivePersistenceSummary
    ) -> Bool {
        guard let jid = descriptor.task.jid,
              jid.isNotEmpty else {
            return false
        }

        if persistenceSummary.visibleRows(
            owner: self.owner,
            jid: jid,
            conversationType: descriptor.task.conversationType
        ) > 0 {
            return true
        }

        let boundaryIds = Set([descriptor.first, descriptor.last].filter(\.isNotEmpty))
        guard boundaryIds.isNotEmpty else {
            return false
        }

        do {
            let realm = try WRealm.safe()
            return realm.objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND opponent == %@ AND conversationType_ == %@ AND isDeleted == false",
                    self.owner,
                    jid,
                    descriptor.task.conversationType.rawValue
                )
                .contains { boundaryIds.contains($0.archivedId) }
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private func traceDeferredArchiveCommitRejection(
        descriptor: DeferredArchiveCommitDescriptor,
        reason: DeferredArchiveCommitRejection
    ) {
        ChatArchiveDebugTrace.log(deferredArchiveTraceEvent(
            purpose: descriptor.task.purpose,
            phase: .failed
        ), [
            ("failedRows", deferredArchiveFailedRowCount(reason))
        ])
    }

    private func deferredArchiveFailedRowCount(
        _ reason: DeferredArchiveCommitRejection
    ) -> Int {
        if case .persistenceFailed(let failedRows) = reason {
            return failedRows
        }
        return 0
    }

    private func deferredArchiveTraceEvent(
        purpose: RequestPurpose,
        phase: DeferredArchiveTracePhase
    ) -> String {
        switch (purpose, phase) {
        case (.bootstrap, .prepared): return "mamBootstrapDeferredPrepared"
        case (.bootstrap, .committed): return "mamBootstrapDeferredCommitted"
        case (.bootstrap, .committedNeedsRepair): return "mamBootstrapDeferredCommittedNeedsRepair"
        case (.bootstrap, .failed): return "mamBootstrapDeferredFailed"
        case (.bootstrap, .aborted): return "mamBootstrapDeferredAborted"
        case (.snapshotRepair, .prepared): return "mamSnapshotRepairDeferredPrepared"
        case (.snapshotRepair, .committed): return "mamSnapshotRepairDeferredCommitted"
        case (.snapshotRepair, .committedNeedsRepair): return "mamSnapshotRepairDeferredCommittedNeedsRepair"
        case (.snapshotRepair, .failed): return "mamSnapshotRepairDeferredFailed"
        case (.snapshotRepair, .aborted): return "mamSnapshotRepairDeferredAborted"
        case (_, .prepared): return "mamArchiveDeferredPrepared"
        case (_, .committed): return "mamArchiveDeferredCommitted"
        case (_, .committedNeedsRepair): return "mamArchiveDeferredCommittedNeedsRepair"
        case (_, .failed): return "mamArchiveDeferredFailed"
        case (_, .aborted): return "mamArchiveDeferredAborted"
        }
    }

    private func shouldValidateBoundaryFingerprint(for task: MAMRequestItem) -> Bool {
        (task.purpose == .bootstrap || task.purpose == .snapshotRepair) &&
            task.conversationType.supportsSnapshotArchiveRepair
    }

    private static func normalizedBoundaryId(_ value: String?) -> String? {
        guard let value,
              value.isNotEmpty else {
            return nil
        }
        return value
    }

    private static func conversationArchiveBoundaryFingerprint(
        chat: LastChatsStorageItem?,
        archiveState: RegularChatArchiveSyncStateStorageItem?
    ) -> ConversationArchiveBoundaryFingerprint {
        ConversationArchiveBoundaryFingerprint(
            chatExists: chat != nil,
            archiveStateExists: archiveState != nil,
            chatSnapshotArchiveId: RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                chat?.syncSnapshotLastArchiveId
            ),
            archiveSnapshotArchiveId: RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                archiveState?.lastSnapshotArchiveId
            ),
            archiveSnapshotMessageId: normalizedBoundaryId(
                archiveState?.lastSnapshotMessageId
            ),
            unreadAfterId: RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                chat?.syncUnreadAfterId
            ),
            unreadCount: max(chat?.syncUnreadCount ?? 0, 0)
        )
    }

    private func captureConversationArchiveBoundaryFingerprint(
        jid: String?,
        conversationType: ClientSynchronizationManager.ConversationType,
        purpose: RequestPurpose
    ) -> ConversationArchiveBoundaryFingerprint? {
        guard (purpose == .bootstrap || purpose == .snapshotRepair),
              conversationType.supportsSnapshotArchiveRepair,
              let jid,
              jid.isNotEmpty else {
            return nil
        }

        do {
            let realm = try WRealm.safe()
            let chat = realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType
                )
            )
            let archiveState = realm.object(
                ofType: RegularChatArchiveSyncStateStorageItem.self,
                forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                    jid: jid,
                    owner: self.owner,
                    conversationType: conversationType
                )
            )
            return Self.conversationArchiveBoundaryFingerprint(
                chat: chat,
                archiveState: archiveState
            )
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    private func applyConversationArchivePageResult(
        task: MAMRequestItem,
        state: MessageArchivePageEndState,
        first: String,
        last: String,
        count: Int
    ) -> (didApply: Bool, boundaryChanged: Bool) {
        guard let jid = task.jid,
              jid.isNotEmpty else {
            return (false, false)
        }

        do {
            let realm = try WRealm.safe()
            let primary = LastChatsStorageItem.genPrimary(
                jid: jid,
                owner: self.owner,
                conversationType: task.conversationType
            )
            var boundaryChanged = false
            try realm.write {
                let chat = realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: primary
                )
                let existingArchiveState = realm.object(
                    ofType: RegularChatArchiveSyncStateStorageItem.self,
                    forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                        jid: jid,
                        owner: self.owner,
                        conversationType: task.conversationType
                    )
                )
                if shouldValidateBoundaryFingerprint(for: task) {
                    let currentFingerprint = Self.conversationArchiveBoundaryFingerprint(
                        chat: chat,
                        archiveState: existingArchiveState
                    )
                    boundaryChanged = task.boundaryFingerprintAtRequestStart == nil ||
                        task.boundaryFingerprintAtRequestStart != currentFingerprint
                }
                let archiveState = RegularChatArchiveSyncStateStorageItem.ensure(
                    owner: self.owner,
                    jid: jid,
                    conversationType: task.conversationType,
                    in: realm
                )
                if count > 0 {
                    archiveState.mergeLoadedRange(first: first, last: last, updateKind: task.coverageUpdateKind)
                }
                switch task.purpose {
                case .bootstrap:
                    archiveState.newerLiveEdgeReached = true
                    if state.archiveEnded {
                        archiveState.olderArchiveEndReached = true
                    }
                case .pageOlder:
                    if state.queryExhausted || state.archiveEnded {
                        archiveState.olderArchiveEndReached = true
                    }
                case .pageNewer:
                    if state.queryExhausted {
                        archiveState.newerLiveEdgeReached = true
                    }
                case .snapshotRepair:
                    if task.nextPage == "" || state.queryExhausted {
                        archiveState.newerLiveEdgeReached = true
                    }
                case .jump, .gapRepair:
                    break
                case .search, .timestampLookup, .latest, .media, .inviteRecovery:
                    break
                }
                archiveState.updatedAt = Date()

                if let chat {
                    chat.lastLoadedMessageHistoryId = archiveState.oldestLoadedArchiveId ?? chat.lastLoadedMessageHistoryId
                    if task.conversationType.supportsSnapshotArchiveRepair {
                        chat.fullArchiveLoaded = archiveState.olderArchiveEndReached
                    }
                    if task.purpose == .bootstrap {
                        chat.isInitialArchiveLoaded = true
                        chat.isSynced = !boundaryChanged && (task.conversationType.supportsSnapshotArchiveRepair
                            ? canClearSnapshotUnsynced(chat: chat, archiveState: archiveState)
                            : archiveState.newerLiveEdgeReached)
                    } else if task.purpose == .pageNewer || task.purpose == .snapshotRepair {
                        let hasDurableNewestCoverage = !boundaryChanged && canClearSnapshotUnsynced(
                            chat: chat,
                            archiveState: archiveState
                        )
                        chat.isSynced = hasDurableNewestCoverage
                        if task.purpose == .snapshotRepair,
                           hasDurableNewestCoverage {
                            // A snapshot repair may be the first archive page
                            // persisted for a newly signed-in account. Once
                            // that newest boundary is durably covered it
                            // satisfies the same initial-readiness contract as
                            // a bootstrap page; leaving this flag false makes
                            // the first chat open start a duplicate MAM.
                            chat.isInitialArchiveLoaded = true
                        }
                    }
                }
            }
            return (true, boundaryChanged)
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
            return (false, false)
        }
    }

    private func canClearSnapshotUnsynced(
        chat: LastChatsStorageItem,
        archiveState: RegularChatArchiveSyncStateStorageItem
    ) -> Bool {
        guard archiveState.newerLiveEdgeReached else {
            return false
        }

        let snapshotArchiveId = RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(archiveState.lastSnapshotArchiveId)
        let snapshotLastCovered: Bool
        if let snapshotArchiveId,
           snapshotArchiveId.isNotEmpty {
            snapshotLastCovered = archiveState.containsArchiveId(snapshotArchiveId)
        } else if let snapshotMessageId = archiveState.lastSnapshotMessageId,
                  snapshotMessageId.isNotEmpty {
            snapshotLastCovered = chat.lastMessageId == snapshotMessageId ||
                chat.lastMessage?.messageId == snapshotMessageId
        } else {
            snapshotLastCovered = true
        }

        guard snapshotLastCovered else {
            return false
        }

        if chat.syncUnreadCount <= 0 {
            return true
        }

        guard let unreadAfterId = chat.syncUnreadAfterId,
              unreadAfterId.isNotEmpty else {
            return false
        }
        if let snapshotArchiveId {
            return archiveState.containsArchiveIdsInSameLoadedRange([snapshotArchiveId, unreadAfterId])
        }
        return archiveState.containsArchiveId(unreadAfterId)
    }
    
    
    internal func requestArchive(_ stream: XMPPStream, jid: String?, isContinues: Bool, conversationType: ClientSynchronizationManager.ConversationType, purpose: RequestPurpose, queryId: String? = nil, searchText: String? = nil, ids: [String]? = nil, flipPage: Bool = true, before: String? = nil, beforeId: String? = nil, afterId: String? = nil, start: Date? = nil, end: Date? = nil, nextPage: String? = nil, prevPage: String? = nil, max: Int? = nil, tags: [Tags] = [], withCounter: Bool = false, coverageUpdateKind: RegularArchiveCoverageUpdateKind = .none, consumerManagesArchiveEnd: Bool = false, consumerManagesHistoryCursor: Bool = false, deferCoverageCommitUntilConsumerProof: Bool = false, callback: (() -> Void)? = nil, requestCallbacks: RequestCallbacks = .none) {
        let isGroupchat = [.group, .channel].contains(conversationType)
        let elementId = queryId ?? "MAM: \(NanoID.new(8))"
        let dateConstraint = self.archiveDateConstraint(
            conversationType: conversationType,
            requestedStart: start,
            requestedEnd: end
        )
        guard !dateConstraint.shouldSkipRequest else {
            self.completeSkippedArchiveRequest(
                queryId: elementId,
                before: before,
                callback: callback,
                requestCallbacks: requestCallbacks
            )
            return
        }
        archiveRequestLifecycleLock.lock()
        archiveRequestLifecycleGeneration &+= 1
        defer { archiveRequestLifecycleLock.unlock() }
        let effectiveStart = dateConstraint.start
        registerArchiveQueryId(elementId, purpose: purpose)
        let query = DDXMLElement(name: "query", xmlns: getPrimaryNamespace())
        query.addAttribute(withName: "queryid", stringValue: elementId)
        let x = DDXMLElement(name: "x", xmlns: "jabber:x:data")
        x.addAttribute(withName: "type", stringValue: "submit")
        let formType = DDXMLElement(name: "field")
        formType.addAttribute(withName: "var", stringValue: "FORM_TYPE")
        formType.addAttribute(withName: "type", stringValue: "hidden")
        formType.addChild(DDXMLElement(name: "value", stringValue: getPrimaryNamespace()))
        x.addChild(formType)
        if let beforeId = beforeId,
           beforeId.isNotEmpty {
            let beforeIdElement = DDXMLElement(name: "field")
            beforeIdElement.addAttribute(withName: "var", stringValue: "before-id")
            beforeIdElement.addChild(DDXMLElement(name: "value", stringValue: beforeId))
            x.addChild(beforeIdElement)
        }
        if let afterId = afterId,
           afterId.isNotEmpty {
            let afterIdElement = DDXMLElement(name: "field")
            afterIdElement.addAttribute(withName: "var", stringValue: "after-id")
            afterIdElement.addChild(DDXMLElement(name: "value", stringValue: afterId))
            x.addChild(afterIdElement)
        }
        if let start = effectiveStart {
            let startElement = DDXMLElement(name: "field")
            startElement.addAttribute(withName: "var", stringValue: "start")
            startElement.addChild(DDXMLElement(name: "value", stringValue: start.XMPPFormattedDate))
            x.addChild(startElement)
        }
        if let end = end {
            let endElement = DDXMLElement(name: "field")
            endElement.addAttribute(withName: "var", stringValue: "end")
            endElement.addChild(DDXMLElement(name: "value", stringValue: end.XMPPFormattedDate))
            x.addChild(endElement)
        }
        if withCounter {
            let counterElement = DDXMLElement(name: "field")
            counterElement.addAttribute(withName: "var", stringValue: "rsm-counter")
            counterElement.addChild(DDXMLElement(name: "value", numberValue: 1))
            x.addChild(counterElement)
        }
        if !isGroupchat {
            if let jid = jid {
                let withElement = DDXMLElement(name: "field")
                withElement.addAttribute(withName: "var", stringValue: "with")
                withElement.addChild(DDXMLElement(name: "value", stringValue: jid))
                x.addChild(withElement)
            }
        }
        if Self.ConversationTypeFilterPolicy.shouldIncludeConversationTypeField(
            conversationType: conversationType,
            purpose: purpose,
            isGroupchat: isGroupchat,
            isExtendedArchiveAvailable: self.isExtendedArchiveAvailable
        ) {
            let ctElement = DDXMLElement(name: "field")
            ctElement.addAttribute(withName: "var", stringValue: "conversation-type")
            ctElement.addChild(DDXMLElement(name: "value", stringValue: conversationType.rawValue))
            x.addChild(ctElement)
        }
        if tags.isNotEmpty {
            let tElement = DDXMLElement(name: "field")
            tElement.addAttribute(withName: "var", stringValue: "with-tags")
            tags.forEach {
                tElement.addChild(DDXMLElement(name: "value", stringValue: $0.rawValue))
            }
            x.addChild(tElement)
        }
        if let searchText = searchText {
            let stElement = DDXMLElement(name: "field")
            stElement.addAttribute(withName: "var", stringValue: "withtext")
            stElement.addChild(DDXMLElement(name: "value", stringValue: searchText))
            x.addChild(stElement)
            self.searchResultsQueries.insert(elementId)
        }
        if let ids,
           ids.isNotEmpty {
            let idsElement = DDXMLElement(name: "field")
            idsElement.addAttribute(withName: "var", stringValue: "ids")
            ids.filter { $0.isNotEmpty }.forEach {
                idsElement.addChild(DDXMLElement(name: "value", stringValue: $0))
            }
            x.addChild(idsElement)
        }
        
        
//        if [.omemo, .omemo1, .axolotl].contains(conversationType)
        query.addChild(x)
        let setElement = DDXMLElement(name: "set", xmlns: "http://jabber.org/protocol/rsm")
        setElement.addChild(DDXMLElement(name: "max", numberValue: (max ?? pageSize) as NSNumber))
        if let nextPage = nextPage {
            setElement.addChild(DDXMLElement(name: "before", stringValue: nextPage))
        } else if nextPage == "" {
            setElement.addChild(DDXMLElement(name: "before"))
        }
        if let prevPage = prevPage {
            setElement.addChild(DDXMLElement(name: "after", stringValue: prevPage))
        }
        query.addChild(setElement)
        if flipPage {
            query.addChild(DDXMLElement(name: "flip-page"))
        }
        let taskId = [jid ?? "global_search", conversationType.rawValue].prp()
        let archiveEndEligibility = self.canMarkArchiveEnd(
            purpose: purpose,
            searchText: searchText,
            ids: ids,
            beforeId: beforeId,
            afterId: afterId,
            start: effectiveStart,
            end: end,
            tags: tags,
            withCounter: withCounter
        ) || (consumerManagesArchiveEnd && purpose == .latest)
        let requestCursorId = (before ?? nextPage).flatMap { cursor in
            cursor.isNotEmpty ? cursor : nil
        }
        let boundaryFingerprintAtRequestStart = captureConversationArchiveBoundaryFingerprint(
            jid: jid,
            conversationType: conversationType,
            purpose: purpose
        )
        let task = MAMRequestItem(
            jid: jid,
            taskID: taskId,
            isGroupchat: isGroupchat,
            messageId: requestCursorId,
            conversationType: conversationType,
            isContinues: isContinues,
            maxDate: effectiveStart,
            searchText: searchText,
            queryId: queryId,
            afterId: afterId,
            nextPage: nextPage,
            prevPage: prevPage,
            max: max ?? pageSize,
            tags: tags,
            start: effectiveStart,
            end: end,
            purpose: purpose,
            coverageUpdateKind: coverageUpdateKind,
            archiveEndEligibility: archiveEndEligibility,
            consumerManagesArchiveEnd: consumerManagesArchiveEnd,
            consumerManagesHistoryCursor: consumerManagesHistoryCursor,
            deferCoverageCommitUntilConsumerProof: deferCoverageCommitUntilConsumerProof,
            boundaryFingerprintAtRequestStart: boundaryFingerprintAtRequestStart
        )
        self.upsertCallbackQueueItem(
            CallbackQueueItem(
                jid: jid ?? "",
                elementId: elementId,
                task: task,
                callback: callback,
                requestCallbacks: requestCallbacks
            )
        )
        Self.registerFallbackEndPageCallbacks(owner: self.owner, queryId: elementId, callbacks: requestCallbacks)
        autoreleasepool {
            self.queryIds.insert(elementId)
        }
        ChatArchiveDebugTrace.log("mamArchiveRequestSend", [
            ("owner", self.owner),
            ("queryId", elementId),
            ("purpose", "\(purpose)"),
            ("conversationType", conversationType.rawValue),
            ("streamKind", Self.streamKind(for: stream).rawValue),
            ("resource", stream.myJID?.resource ?? "-"),
            ("jid", jid ?? "-"),
            ("before", nextPage ?? "-"),
            ("after", prevPage ?? "-"),
            ("max", max ?? pageSize),
            ("flipPage", flipPage),
            ("archiveProducing", purpose.isArchiveHistoryProducing)
        ])
        if isGroupchat {
            stream.send(XMPPIQ(iqType: .set, to: jid == nil ? nil : XMPPJID(string: jid ?? ""), elementID: elementId, child: query))
        } else {
            stream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: query))
        }
    }

    @discardableResult
    internal func fetchAnchorMessage(
        _ stream: XMPPStream,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        archivedId: String,
        queryId: String? = nil,
        callback: (() -> Void)? = nil,
        requestCallbacks: RequestCallbacks = .none
    ) -> String {
        let requestQueryId = queryId ?? "MAM jump exact: \(NanoID.new(6))"
        if conversationType == .regular {
            let plan = Self.regularExactAnchorRequestPlan(jid: jid, archivedId: archivedId)
            return startRegularArchiveRequest(
                stream,
                plan: plan,
                queryId: requestQueryId,
                flipPage: false,
                callback: callback,
                requestCallbacks: requestCallbacks
            )
        }
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .jump,
            queryId: requestQueryId,
            ids: [archivedId],
            flipPage: false,
            max: 1,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
        return requestQueryId
    }

    @discardableResult
    internal func fetchAnchorWindow(
        _ stream: XMPPStream,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        start: Date,
        end: Date,
        max: Int,
        queryId: String? = nil,
        callback: (() -> Void)? = nil,
        requestCallbacks: RequestCallbacks = .none
    ) -> String {
        let requestQueryId = queryId ?? "MAM jump window: \(NanoID.new(6))"
        if conversationType == .regular {
            let plan = Self.regularDateWindowAnchorRequestPlan(
                jid: jid,
                start: start,
                end: end,
                max: max
            )
            return startRegularArchiveRequest(
                stream,
                plan: plan,
                queryId: requestQueryId,
                flipPage: false,
                callback: callback,
                requestCallbacks: requestCallbacks
            )
        }
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .jump,
            queryId: requestQueryId,
            ids: nil,
            flipPage: false,
            start: start,
            end: end,
            max: max,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
        return requestQueryId
    }
    
    public final func getLastMessage(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .latest,
            nextPage: "",
            max: 1
        )
    }
    
    public final func getLastMessages(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        do {
            let realm = try WRealm.safe()
            if (realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType))?.isSynced ?? false) == false {
                self.requestArchive(
                    stream,
                    jid: jid,
                    isContinues: false,
                    conversationType: conversationType,
                    purpose: .latest,
                    nextPage: "",
                    max: self.pageSize
                )
            }
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
        }
        
    }

    @discardableResult
    public final func requestInviteRecovery(_ stream: XMPPStream, max: Int = 100) -> String? {
        guard isExtendedArchiveAvailable else {
            return nil
        }
        let queryId = "MAM invite recovery: \(NanoID.new(8))"
        requestArchive(
            stream,
            jid: nil,
            isContinues: false,
            conversationType: .group,
            purpose: .inviteRecovery,
            queryId: queryId,
            flipPage: false,
            nextPage: "",
            max: max,
            tags: [.invite],
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true
        )
        return queryId
    }
    
    
    class HistoryGap {
        var newestMessageId: String
        var oldestMessageId: String
        var startDate: Date
        var endDate: Date
        
        init(newestMessageId: String, oldestMessageId: String, startDate: Date, endDate: Date) {
            self.newestMessageId = newestMessageId
            self.oldestMessageId = oldestMessageId
            self.startDate = Date(timeIntervalSince1970: startDate.timeIntervalSince1970 + 600)
            self.endDate = Date(timeIntervalSince1970: endDate.timeIntervalSince1970 - 600)
        }
    }
    
    @discardableResult
    internal final func syncChat(
        _ stream: XMPPStream,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        pageSize: Int? = nil,
        queryId: String? = nil,
        callback: (() -> Void)?,
        requestCallbacks: RequestCallbacks = .none,
        deferCoverageCommitUntilConsumerProof: Bool = true
    ) -> SyncChatStartResult {
        let effectivePageSize = conversationType == .regular
            ? Self.regularArchivePageSize(requested: pageSize, defaultPageSize: self.pageSize)
            : (pageSize ?? self.pageSize)
        do {
            let realm = try WRealm.safe()
            let primary = LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType)
            if realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary) == nil {
                try realm.write {
                    let instance = LastChatsStorageItem()
                    instance.owner = owner
                    instance.jid = jid
                    instance.conversationType = conversationType
                    instance.messageDate = Date()
                    instance.setPrimary(withOwner: owner)
                    instance.isSynced = false
                    if let rosterItem = realm
                        .object(ofType: RosterStorageItem.self,
                                forPrimaryKey: [jid, owner].prp()) {
                        instance.rosterItem = rosterItem
                        rosterItem.associatedLastChat = instance
                    } else {
                        let rosterItem = RosterStorageItem()
                        rosterItem.owner = owner
                        rosterItem.jid = jid
                        rosterItem.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
                        rosterItem.groups.append(RosterUtils.ungroupped)
                        rosterItem.associatedLastChat = instance
                        realm.add(rosterItem)
                        instance.rosterItem = rosterItem
                    }
                    instance.rosterItem = realm.object(ofType: RosterStorageItem.self, forPrimaryKey: [jid, owner].prp())
                    realm.add(instance, update: .modified)
                }
            }

            if let lastChatInstance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary) {
                let localMessageCount = realm
                    .objects(MessageStorageItem.self)
                    .filter(
                        "opponent == %@ AND owner == %@ AND conversationType_ == %@ AND isDeleted == false",
                        jid,
                        self.owner,
                        conversationType.rawValue
                    )
                    .count
                let archiveState = conversationType.supportsSnapshotArchiveRepair
                    ? realm.object(
                        ofType: RegularChatArchiveSyncStateStorageItem.self,
                        forPrimaryKey: RegularChatArchiveSyncStateStorageItem.genPrimary(
                            jid: jid,
                            owner: self.owner,
                            conversationType: conversationType
                        )
                    )
                    : nil
                let hasKnownRemoteBoundary = conversationType.supportsSnapshotArchiveRepair && (
                    RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                        lastChatInstance.syncSnapshotLastArchiveId
                    ) != nil ||
                    RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                        archiveState?.lastSnapshotArchiveId
                    ) != nil ||
                    archiveState?.lastSnapshotMessageId?.isNotEmpty == true ||
                    (
                        lastChatInstance.syncUnreadCount > 0 &&
                        RegularChatArchiveSyncStateStorageItem.normalizedArchiveId(
                            lastChatInstance.syncUnreadAfterId
                        ) != nil
                    )
                )
                let shouldStartBootstrap = Self.ChatBootstrapRequestPolicy.shouldStartInitialBootstrap(
                    isSynced: lastChatInstance.isSynced,
                    isInitialArchiveLoaded: lastChatInstance.isInitialArchiveLoaded,
                    localMessageCount: localMessageCount,
                    hasKnownRemoteBoundary: hasKnownRemoteBoundary
                )
                if !shouldStartBootstrap {
                    // Keep chat open deterministic: synced chats should render local state immediately
                    // and let explicit user paging own further archive loads.
                    return .noop
                } else {
                    // `isSynced` and `isInitialArchiveLoaded` are durable
                    // readiness flags. Once their proof is missing or known to
                    // be inconsistent, invalidate both before transport starts;
                    // only `commitAfterPersistence` may restore them.
                    if lastChatInstance.isSynced || lastChatInstance.isInitialArchiveLoaded {
                        try realm.write {
                            lastChatInstance.isSynced = false
                            lastChatInstance.isInitialArchiveLoaded = false
                        }
                    }
                    var archiveStart: Date? = nil
                    if conversationType.isEncrypted {
                        if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                            archiveStart = instance.createdAt
                        }
                    }
                    let bootstrapQueryId = queryId ?? "MAM bootstrap history: \(NanoID.new(6))"
                    if conversationType == .regular {
                        let plan = Self.regularBootstrapRequestPlan(jid: jid, pageSize: effectivePageSize)
                        let resolvedQueryId = startRegularArchiveRequest(
                            stream,
                            plan: plan,
                            queryId: bootstrapQueryId,
                            joinDuplicateRequests: queryId == nil,
                            callback: callback,
                            requestCallbacks: requestCallbacks,
                            deferCoverageCommitUntilConsumerProof: deferCoverageCommitUntilConsumerProof
                        )
                        return .bootstrapStarted(queryId: resolvedQueryId)
                    }
                    let bootstrapRequest = Self.newestBootstrapPageRequest(pageSize: effectivePageSize)
                    self.requestArchive(
                        stream, jid: jid,
                        isContinues: false,
                        conversationType: conversationType,
                        purpose: .bootstrap,
                        queryId: bootstrapQueryId,
                        start: archiveStart,
                        nextPage: bootstrapRequest.nextPage,
                        prevPage: bootstrapRequest.prevPage,
                        max: bootstrapRequest.max,
                        coverageUpdateKind: .bootstrapNewest,
                        consumerManagesArchiveEnd: true,
                        consumerManagesHistoryCursor: true,
                        deferCoverageCommitUntilConsumerProof: deferCoverageCommitUntilConsumerProof,
                        callback: callback,
                        requestCallbacks: requestCallbacks
                    )
                    return .bootstrapStarted(queryId: bootstrapQueryId)
                }
            }
            
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
        }
        return .noop
    }
    
    @discardableResult
    internal func requestNewerHistoryPage(_ stream: XMPPStream, for jid: String, conversationType: ClientSynchronizationManager.ConversationType, messageId: String, pageSize: Int? = nil, queryId: String? = nil, callback: (() -> Void)? = nil, requestCallbacks: RequestCallbacks = .none, deferCoverageCommitUntilConsumerProof: Bool = false) -> String {
        let effectivePageSize = conversationType == .regular
            ? Self.regularArchivePageSize(requested: pageSize, defaultPageSize: self.pageSize)
            : (pageSize ?? self.pageSize)
        let pageRequest = Self.newerPageRequest(messageId: messageId, pageSize: effectivePageSize)
        let requestQueryId = queryId ?? "MAM prev history: \(NanoID.new(6))"
        if conversationType == .regular {
            let plan = Self.regularNewerRequestPlan(jid: jid, newestLoadedArchiveId: messageId, pageSize: effectivePageSize)
            return startRegularArchiveRequest(
                stream,
                plan: plan,
                queryId: requestQueryId,
                joinDuplicateRequests: queryId == nil,
                callback: callback,
                requestCallbacks: requestCallbacks,
                deferCoverageCommitUntilConsumerProof: deferCoverageCommitUntilConsumerProof
            )
        }
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .pageNewer,
            queryId: requestQueryId,
            searchText: nil,
            flipPage: true,
            before: nil,
            beforeId: nil,
            afterId: nil,
            start: nil,//lastMsgDate,//modifiedDate,
            end: nil,
            nextPage: pageRequest.nextPage,
            prevPage: pageRequest.prevPage,
            max: pageRequest.max,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            deferCoverageCommitUntilConsumerProof: deferCoverageCommitUntilConsumerProof,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
        return requestQueryId
    }
    
    @discardableResult
    internal func requestOlderHistoryPage(_ stream: XMPPStream, for jid: String, conversationType: ClientSynchronizationManager.ConversationType, messageId: String?, pageSize: Int? = nil, queryId: String? = nil, callback: (() -> Void)? = nil, requestCallbacks: RequestCallbacks = .none, deferCoverageCommitUntilConsumerProof: Bool = false) -> String {
        let effectivePageSize = conversationType == .regular
            ? Self.regularArchivePageSize(requested: pageSize, defaultPageSize: self.pageSize)
            : (pageSize ?? self.pageSize)
        let pageRequest = Self.olderPageRequest(messageId: messageId, pageSize: effectivePageSize)
        let requestQueryId = queryId ?? "MAM next history: \(NanoID.new(6))"
        if conversationType == .regular {
            let plan = Self.regularOlderRequestPlan(jid: jid, oldestLoadedArchiveId: messageId, pageSize: effectivePageSize)
            return startRegularArchiveRequest(
                stream,
                plan: plan,
                queryId: requestQueryId,
                joinDuplicateRequests: queryId == nil,
                callback: callback,
                requestCallbacks: requestCallbacks,
                deferCoverageCommitUntilConsumerProof: deferCoverageCommitUntilConsumerProof
            )
        }
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: false,
            conversationType: conversationType,
            purpose: .pageOlder,
            queryId: requestQueryId,
            searchText: nil,
            flipPage: true,
            before: nil,
            beforeId: nil,
            afterId: nil,
            start: nil,
            end: nil,
            nextPage: pageRequest.nextPage,
            prevPage: pageRequest.prevPage,
            max: pageRequest.max,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            deferCoverageCommitUntilConsumerProof: deferCoverageCommitUntilConsumerProof,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
        return requestQueryId
    }

    @discardableResult
    internal func getRegularGapRepairHistory(
        _ stream: XMPPStream,
        for jid: String,
        gap: RegularChatArchiveGap,
        direction: RegularArchiveGapRepairDirection,
        pageSize: Int? = nil,
        queryId: String? = nil,
        callback: (() -> Void)? = nil,
        requestCallbacks: RequestCallbacks = .none,
        deferCoverageCommitUntilConsumerProof: Bool = false
    ) -> String {
        getGapRepairHistory(
            stream,
            for: jid,
            conversationType: .regular,
            gap: gap,
            direction: direction,
            pageSize: pageSize,
            queryId: queryId,
            callback: callback,
            requestCallbacks: requestCallbacks,
            deferCoverageCommitUntilConsumerProof: deferCoverageCommitUntilConsumerProof
        )
    }

    @discardableResult
    internal func getGapRepairHistory(
        _ stream: XMPPStream,
        for jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        gap: RegularChatArchiveGap,
        direction: RegularArchiveGapRepairDirection,
        pageSize: Int? = nil,
        queryId: String? = nil,
        callback: (() -> Void)? = nil,
        requestCallbacks: RequestCallbacks = .none,
        deferCoverageCommitUntilConsumerProof: Bool = false
    ) -> String {
        let effectivePageSize = Self.regularArchivePageSize(requested: pageSize, defaultPageSize: self.pageSize)
        let plan = Self.archiveGapRepairRequestPlan(
            jid: jid,
            conversationType: conversationType,
            gap: gap,
            direction: direction,
            pageSize: effectivePageSize
        )
        let requestQueryId = queryId ?? "MAM gap repair history: \(NanoID.new(6))"
        return startRegularArchiveRequest(
            stream,
            plan: plan,
            queryId: requestQueryId,
            joinDuplicateRequests: queryId == nil,
            callback: callback,
            requestCallbacks: requestCallbacks,
            deferCoverageCommitUntilConsumerProof: deferCoverageCommitUntilConsumerProof
        )
    }
    
    private final func checkShouldLoadFullHistory(for jid: String, conversationType: ClientSynchronizationManager.ConversationType) throws -> Bool {
        
        let realm = try WRealm.safe()
        if let instance = realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: self.owner, conversationType: conversationType)) {
            let taskId = [jid, conversationType.rawValue].prp()
            if instance.isAllHistoryLoaded {
                return false
            }
            if self.continuesTaskID == nil {
                return true
            }
            if self.continuesTaskID == taskId {
                return false
            }
//            let msgCount = realm.objects(MessageStorageItem.self).filter("opponent == %@ AND owner == %@ AND conversationType_ == %@", jid, self.owner, conversationType.rawValue).count
            
            if !instance.fullArchiveLoaded {
                return true
            }
        } else {
            return false
        }
        return false
    }
    
    public final func startLoadHistory(_ stream: XMPPStream, jid: String, conversationType: ClientSynchronizationManager.ConversationType) throws {
        let taskId = [jid, conversationType.rawValue].prp()
        if let continuesTaskID = continuesTaskID {
            if taskId != continuesTaskID {
                if let item = self.firstCallbackQueueItem(where: { $0.task.taskID == continuesTaskID }) {
                    item.callback?()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                        self.removeCallbackQueueItem(item)
                    }
                }
            }
        }
        
        let realm = try WRealm.safe()
        let messageId = realm
            .objects(MessageStorageItem.self)
            .filter("opponent == %@ AND owner == %@ AND conversationType_ == %@", jid, self.owner, conversationType.rawValue)
            .sorted (byKeyPath: "date", ascending: false)
            .last?
            .archivedId
        
        var archiveStart: Date? = nil
        if conversationType.isEncrypted {
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.owner) {
                archiveStart = instance.createdAt
            }
        }
        
        self.requestArchive(
            stream,
            jid: jid,
            isContinues: true,
            conversationType: conversationType,
            purpose: .pageOlder,
            before: messageId,
            start: archiveStart
        )
        self.continuesTaskID = taskId
    }
    
    public final func continueLoadHistory(_ stream: XMPPStream, task: MAMRequestItem, nextPage: String?, requestCallbacks: RequestCallbacks = .none, callback: (() -> Void)? = nil) {
//        guard continuesTaskID == task.taskID else { return }
        guard let nextPage = nextPage else {
            if let item = self.firstCallbackQueueItem(where: { $0.task.taskID == task.taskID }) {
                item.callback?()
                self.removeCallbackQueueItem(item)
            }
            return
        }
        
//        if let item = self.callbacksQueue.first(where: { $0.task.taskID == continuesTaskID }) {
//            self.callbacksQueue.remove(item)
//        }
        
        self.requestArchive(
            stream,
            jid: task.jid,
            isContinues: true,
            conversationType: task.conversationType,
            purpose: task.purpose,
            queryId: task.queryId,
            searchText: task.searchText,
            before: task.messageId,
            afterId: task.afterId,
            start: task.start,
            end: task.end,
            nextPage: nextPage,
            max: task.max,
            tags: task.tags,
            coverageUpdateKind: task.coverageUpdateKind,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
    }
    
    public final func endLoadHistory(jid: String, conversationType: ClientSynchronizationManager.ConversationType) {
        let taskId = [jid, conversationType.rawValue].prp()
        if let continuesTaskID = continuesTaskID, continuesTaskID == taskId {
            if let item = self.firstCallbackQueueItem(where: { $0.task.taskID == continuesTaskID }) {
                item.callback?()
                self.removeCallbackQueueItem(item)
            }
            self.continuesTaskID = nil
        }
    }
    
    public func readMessage(_ message: XMPPMessage) -> Bool {
        guard let queryId = message.element(forName: "result")?.attributeStringValue(forName: "queryid") else {
            return false
        }
        if !self.searchResultsQueries.contains(queryId) {
            return false
        }
        if let date = getDelayedDate(message),
            let messageBare = getArchivedMessageContainer(message) {
            let item = MessageManager.MessageQueueItem(messageBare,
                                     messageId: getOriginId(messageBare),
                                     archivedFrom: message.from?.bare,
                                     isRead: true,
                                     date: getDeliveryTime(messageBare, owner: owner) ?? date,
                                     state: .deliver,
                                     queryId: getMAMQueryId(message))
            
            
            
            if isVoIPMessage(item.message) {
                return true
            }
            let instance: MessageStorageItem = MessageStorageItem()
            let from = item.message.from?.bare ?? item.archivedFrom ?? item.originalFrom
            guard let to = item.message.to?.bare else {
                    return true
            }
            if let formElement = item.message.element(forName: "x", xmlns: "jabber:x:data"),
                formElement.attributeStringValue(forName: "type") == "submit" {
                return true
            }
            let opponent = to != owner ? to : from
            
            var omemoError: Bool = !(item.message.element(forName: "omemo-result__system")?.attributeBoolValue(forName: "result") ?? false)
            var errorMetadata: [String: Any] = [:]
            var isEncryptedMessage: Bool = false
            if item.message.element(forName: "encrypted") != nil {
                isEncryptedMessage = true
                errorMetadata = SignatureManager.MessageError().errorMetadata
            }
            
            let afterburnInterval = item.message.element(forName: "ephemeral", xmlns: "urn:xmpp:ephemeral:0")?.attributeDoubleValue(forName: "timer") ?? 0
            
            var hasSignElement: Bool = false
            var envelopeContainer: String? = nil
//            print("RECEIVER", #function, item.message.prettyXMLString!)
            if let sign = item.message.element(forName: "time-signature", xmlns: SignatureManager.xmlns){
                omemoError = false
                hasSignElement = true
                envelopeContainer = sign.xmlString
                do {
                    errorMetadata = try SignatureManager.shared.checkSignature(
                        owner: self.owner,
                        for: from,
                        signature: sign,
                        messageDate: item.date
                    ).errorMetadata
                } catch {
                    errorMetadata = SignatureManager.MessageError().errorMetadata
                }
            }
            
            if let userId = groupchatUserElement(from: item.message)?
                .attributeStringValue(forName: "id") {
                if let userCard = item.groupchatUserCard,
                    let myId = userCard.attributeStringValue(forName: "id") {
                    item.originalOutgoing = userId == myId
                } else {
                    do {
                        let realm = try WRealm.safe()
                        if let instance = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: [userId, opponent, owner].prp()) {
                            item.originalOutgoing = instance.isMe
                        }
                    } catch {
                        DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                    }
                }
            } else if let groupchatRef = item.message
                    .element(forName: "x", xmlns: "https://xabber.com/protocol/groups")?
                    .elements(forName: "reference"),
                      let groupchatAuthor = MessageManager.getMessageAuthorGroupchatStatic(groupchatRef, jid: opponent, owner: self.owner) {
                    item.originalOutgoing = groupchatAuthor == owner
            } else {
                item.originalOutgoing = from == owner
            }
            
//            if item.originalOutgoing || item.state == .read {
//                item.isRead = true
            let conversationType = conversationTypeByMessage(item.message)
            let readDate = item.readDate ??  nil
            if let readDate = readDate,
               item.date < readDate {
                item.isRead = true
            } else {
                item.isRead = item.state == .read
            }
            if parseSystemMessageMetadata(item.message) != nil {
                instance.configureSystemMessage(item.message,
                                                owner: owner,
                                                opponent: opponent,
                                                date: item.date)
                instance.state = .none
                instance.isRead = item.forceUnreadState ?? item.isRead
            } else {
                instance.configureIncomingMessage(item.message,
                                          owner: owner,
                                          opponent: opponent,
                                          outgoing: item.originalOutgoing,
                                          isRead: item.forceUnreadState ?? item.isRead,
                                          date: item.date, isEncrypted: isEncryptedMessage)
                instance.forceUnreadState = item.forceUnreadState
                instance.state = item.state
                
            }
            instance.envelopeContainer = envelopeContainer
            instance.updatePrimary()
            if afterburnInterval > 0 {
                instance.applyAutoDeleteTTL(afterburnInterval, startsAt: item.date)
            } else {
                instance.afterburnInterval = afterburnInterval
            }
            
            if hasSignElement {
                instance.errorMetadata = errorMetadata
            }
            
                      
            
            if isEncryptedMessage {
                if !errorMetadata.isEmpty {
                    if omemoError {
                        instance.messageError = "omemo"
                    } else {
                        if hasSignElement {
                            instance.messageError = "cert_error"
                        }
                    }
                }
            }
            
            if afterburnInterval > 0 {
                if isEncryptedMessage {
                    if !errorMetadata.isEmpty {
                        if omemoError {
                            instance.markDeleted()
                        }
                    }
                }
            }
            if let readDate = readDate,
               afterburnInterval > 0 {
                instance.isRead = true
                if !item.originalOutgoing {
                    instance.state = .read
                }
                instance.readDate = readDate.timeIntervalSince1970
                if instance.autoDeleteExpiresAt <= 0 {
                    instance.burnDate = readDate.timeIntervalSince1970 + afterburnInterval
                }
                
                
                if instance.effectiveAutoDeleteExpiresAt > 0,
                   instance.effectiveAutoDeleteExpiresAt <= Date().timeIntervalSince1970 {
                    instance.markAutoDeleted()
                }
            }
            if instance.autoDeleteExpiresAt > 0,
               instance.autoDeleteExpiresAt <= Date().timeIntervalSince1970 {
                instance.markAutoDeleted()
            }
            
            let requestCallbacks: RequestCallbacks
            let searchResultId: ChatSearchResult.ID? = instance.archivedId.isNotEmpty
                ? .archived(instance.archivedId)
                : (instance.primary.isNotEmpty ? .primary(instance.primary) : nil)
            if self.hasActiveSearchArchiveSession(queryId: queryId) {
                guard let searchResultId,
                      let searchAccepted = self.acceptSearchArchiveResult(
                          queryId: queryId,
                          id: searchResultId,
                          date: instance.date
                      ) else {
                    return true
                }
                guard searchAccepted else {
                    return true
                }
                requestCallbacks = self.searchArchiveCallbacks(queryId: queryId) ?? .none
            } else {
                requestCallbacks = self.firstCallbackQueueItem(where: {
                    $0.elementId == queryId
                })?.requestCallbacks ?? .none
            }
            self.notifyDidReceiveMessage(instance, queryId: queryId, callbacks: requestCallbacks)
        }
        return true
    }

    internal func scheduleRegularIdleBackfillIfNeeded(delay: TimeInterval = 0.25) {
        let shouldSchedule = withRegularIdleBackfillTriggerState {
            $0.registerExplicitTrigger()
        }
        guard shouldSchedule else {
            return
        }
        scheduleRegisteredRegularIdleBackfillAttempt(delay: delay)
    }

    private func scheduleRegisteredRegularIdleBackfillAttempt(delay: TimeInterval = 0.25) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.startNextRegularIdleBackfillIfNeeded()
        }
    }

    private func finishRegularIdleBackfillAttempt(
        _ token: RegularIdleBackfillAttemptToken,
        requiresRetry: Bool = false
    ) {
        let shouldSchedulePendingTrigger = withRegularIdleBackfillTriggerState {
            $0.finishAttempt(token, requiresRetry: requiresRetry)
        }
        if shouldSchedulePendingTrigger {
            scheduleRegisteredRegularIdleBackfillAttempt()
        }
    }

    private func withRegularIdleBackfillTriggerState<T>(
        _ body: (inout RegularIdleBackfillTriggerState) -> T
    ) -> T {
        regularIdleBackfillTriggerLock.lock()
        defer { regularIdleBackfillTriggerLock.unlock() }
        return body(&regularIdleBackfillTriggerState)
    }

    internal func scheduleSnapshotArchiveRepairs(_ targets: [SnapshotRepairTarget]) {
        guard targets.isNotEmpty,
              AccountManager.shared.find(for: self.owner) != nil else {
            return
        }

        var seen = Set<SnapshotRepairTarget>()
        var acceptedTargets: [(target: SnapshotRepairTarget, hasPredecessor: Bool, pendingCount: Int)] = []
        snapshotRepairPumpLock.lock()
        targets.forEach { target in
            guard target.conversationType.supportsSnapshotArchiveRepair,
                  seen.insert(target).inserted,
                  scheduledSnapshotRepairTargets.insert(target).inserted else {
                return
            }
            let hasPredecessor = activeSnapshotRepairTarget != nil ||
                pendingSnapshotRepairTargets.isNotEmpty
            pendingSnapshotRepairTargets.append(target)
            snapshotRepairPriorityByTarget[target] = .background
            snapshotRepairFollowUpCountByTarget[target] = 0
            snapshotRepairEnqueuedAtByTarget[target] = Date()
            acceptedTargets.append((
                target: target,
                hasPredecessor: hasPredecessor,
                pendingCount: pendingSnapshotRepairTargets.count
            ))
        }
        let targetToStart: (target: SnapshotRepairTarget, priority: AccountXMPPTaskScheduler.Priority)?
        if activeSnapshotRepairTarget == nil,
           pendingSnapshotRepairTargets.isNotEmpty {
            let target = pendingSnapshotRepairTargets.removeFirst()
            activeSnapshotRepairTarget = target
            targetToStart = (
                target,
                snapshotRepairPriorityByTarget[target] ?? .background
            )
        } else {
            targetToStart = nil
        }
        snapshotRepairPumpLock.unlock()

        acceptedTargets.forEach { accepted in
            snapshotRepairEnqueueObserver?(
                accepted.target,
                .background,
                accepted.target.deduplicationKey(owner: self.owner)
            )
            ChatArchiveDebugTrace.log("mamSnapshotRepairEnqueued", [
                ("hasPredecessor", accepted.hasPredecessor),
                ("pendingCount", accepted.pendingCount)
            ])
        }

        if let targetToStart {
            enqueueSnapshotArchiveRepair(
                targetToStart.target,
                priority: targetToStart.priority
            )
        }
    }

    private func enqueueSnapshotArchiveRepair(
        _ target: SnapshotRepairTarget,
        priority: AccountXMPPTaskScheduler.Priority
    ) {
        // A target may wait behind another repair while an interactive chat
        // transaction commits it. Re-check durable state before reserving a
        // second wire request.
        if isSnapshotArchiveRepairSatisfied(target) {
            finishSnapshotRepairPump(target)
            return
        }
        guard let account = AccountManager.shared.find(for: self.owner) else {
            finishSnapshotRepairPump(target)
            return
        }

        let key = ChatInitialBootstrapRequestKey(
            owner: self.owner,
            jid: target.jid,
            conversationType: target.conversationType
        )
        let coordinator = ChatInitialBootstrapRequestCoordinator.shared
        let proposedQueryId = "MAM snapshot repair: \(NanoID.new(6))"
        snapshotRepairPumpLock.lock()
        let enqueuedAt = snapshotRepairEnqueuedAtByTarget[target] ?? Date()
        snapshotRepairPumpLock.unlock()

        let acquisition = coordinator.acquireOrJoin(
            key: key,
            proposedQueryId: proposedQueryId,
            timeout: ChatInteractiveRemoteArchiveTimeoutPolicy.timeout,
            purpose: .snapshotRepair,
            persistenceTimeout: self.archivePersistenceTerminalTimeout,
            observer: { _, _, _ in }
        )

        let lease: ChatInitialBootstrapRequestCoordinator.Lease
        switch acquisition {
        case .terminal:
            coordinator.clearTerminal(key: key)
            finishSnapshotRepairPump(target, requiresFollowUpRepair: true)
            return
        case .start(let acquiredLease), .joined(let acquiredLease):
            lease = acquiredLease
        }

        let observationLock = NSLock()
        var observationToken: ChatInitialBootstrapRequestCoordinator.ObservationToken?
        var pendingTerminalReadiness: ConversationArchiveReadiness?
        var didFinishObservation = false
        let finishObservedLease: (ConversationArchiveReadiness) -> Void = { [weak self] readiness in
            var token: ChatInitialBootstrapRequestCoordinator.ObservationToken?
            observationLock.lock()
            guard !didFinishObservation else {
                observationLock.unlock()
                return
            }
            guard observationToken != nil else {
                pendingTerminalReadiness = readiness
                observationLock.unlock()
                return
            }
            didFinishObservation = true
            token = observationToken
            observationToken = nil
            pendingTerminalReadiness = nil
            observationLock.unlock()

            if let token {
                coordinator.detach(key: key, observation: token)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let requiresFollowUpRepair = readiness.phase == .failed ||
                    !readiness.hasDurableCoverage
                if readiness.phase == .committed {
                    _ = coordinator.complete(
                        key: key,
                        queryId: lease.queryId,
                        unregisterPersistenceSource: true
                    )
                } else {
                    coordinator.clearTerminal(key: key)
                }
                self.finishSnapshotRepairPump(
                    target,
                    requiresFollowUpRepair: requiresFollowUpRepair
                )
            }
        }
        let installedObservationToken = coordinator.observe(key: key) { readiness in
            guard let readiness,
                  readiness.isTerminal else {
                return
            }
            finishObservedLease(readiness)
        }
        observationLock.lock()
        observationToken = installedObservationToken
        let immediateTerminalReadiness = pendingTerminalReadiness
        observationLock.unlock()
        if let immediateTerminalReadiness {
            finishObservedLease(immediateTerminalReadiness)
        }

        guard case .start = acquisition else {
            if priority == .interactive {
                _ = coordinator.promote(key: key)
            }
            return
        }

        let startFailure: () -> Void = {
            let event = MessageArchiveRequestFailureEvent(
                owner: key.owner,
                queryId: lease.queryId,
                streamKind: .primary,
                reason: .requestStartFailed,
                errorDescription: "Snapshot archive transport unavailable",
                pendingQueryCount: 1
            )
            _ = coordinator.recordFailure(key: key, event: event, publishEvent: true)
        }
        account.xmppTaskScheduler.enqueueAccountTask(
            priority: priority,
            resource: .mamArchive,
            deduplicationKey: key.schedulerDeduplicationKey,
            requiresAuthenticatedStream: true,
            unavailable: startFailure
        ) { [weak self] user, stream, finish in
            guard let self,
                  coordinator.isActive(key: key, queryId: lease.queryId) else {
                finish()
                return
            }
            ChatArchiveDebugTrace.log(
                priority == .interactive
                    ? "mamSnapshotRepairFollowUpStarted"
                    : "mamSnapshotRepairBackgroundStarted",
                [("waitMs", ChatArchiveDebugTrace.milliseconds(since: enqueuedAt))]
            )
            coordinator.attachSchedulerCompletion(
                key: key,
                queryId: lease.queryId,
                completion: finish
            )
            coordinator.preparePersistenceSource(
                key: key,
                queryId: lease.queryId,
                messages: user.messages,
                archiveManager: user.mam
            )
            let startedQueryId = user.mam.startSnapshotArchiveRepair(
                stream,
                target: target,
                queryId: lease.queryId,
                callback: nil,
                requestCallbacks: .none
            )
            guard startedQueryId == lease.queryId else {
                startFailure()
                return
            }
            coordinator.resolveStart(
                key: key,
                queryId: lease.queryId,
                result: .bootstrapStarted(queryId: lease.queryId),
                messages: user.messages,
                archiveManager: user.mam,
                cancelTransport: {
                    _ = user.mam.cancelPendingArchiveRequest(queryId: lease.queryId)
                }
            )
        }
    }

    private func isSnapshotArchiveRepairSatisfied(
        _ target: SnapshotRepairTarget
    ) -> Bool {
        do {
            let realm = try WRealm.safe()
            return realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(
                    jid: target.jid,
                    owner: self.owner,
                    conversationType: target.conversationType
                )
            )?.isSynced == true
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
            return false
        }
    }

    private func finishSnapshotRepairPump(
        _ target: SnapshotRepairTarget,
        requiresFollowUpRepair: Bool = false
    ) {
        snapshotRepairPumpLock.lock()
        guard activeSnapshotRepairTarget == target else {
            snapshotRepairPumpLock.unlock()
            return
        }

        let currentFollowUpCount = snapshotRepairFollowUpCountByTarget[target] ?? 0
        let shouldScheduleFollowUp = requiresFollowUpRepair && currentFollowUpCount < 1
        let didExhaustFollowUp = requiresFollowUpRepair && !shouldScheduleFollowUp
        activeSnapshotRepairTarget = nil
        if shouldScheduleFollowUp {
            snapshotRepairFollowUpCountByTarget[target] = currentFollowUpCount + 1
            snapshotRepairPriorityByTarget[target] = .interactive
            snapshotRepairEnqueuedAtByTarget[target] = Date()
            pendingSnapshotRepairTargets.insert(target, at: 0)
        } else {
            scheduledSnapshotRepairTargets.remove(target)
            snapshotRepairPriorityByTarget.removeValue(forKey: target)
            snapshotRepairFollowUpCountByTarget.removeValue(forKey: target)
            snapshotRepairEnqueuedAtByTarget.removeValue(forKey: target)
        }

        let nextTarget: (target: SnapshotRepairTarget, priority: AccountXMPPTaskScheduler.Priority)?
        if pendingSnapshotRepairTargets.isNotEmpty {
            let target = pendingSnapshotRepairTargets.removeFirst()
            activeSnapshotRepairTarget = target
            nextTarget = (
                target,
                snapshotRepairPriorityByTarget[target] ?? .background
            )
        } else {
            nextTarget = nil
        }
        snapshotRepairPumpLock.unlock()

        if shouldScheduleFollowUp {
            snapshotRepairEnqueueObserver?(
                target,
                .interactive,
                target.deduplicationKey(owner: self.owner)
            )
            ChatArchiveDebugTrace.log("mamSnapshotRepairFollowUpEnqueued", [
                ("attempt", currentFollowUpCount + 1)
            ])
        } else if didExhaustFollowUp {
            ChatArchiveDebugTrace.log("mamSnapshotRepairFollowUpFailed", [
                ("attempt", currentFollowUpCount)
            ])
        }

        if let nextTarget {
            enqueueSnapshotArchiveRepair(
                nextTarget.target,
                priority: nextTarget.priority
            )
        }
    }

    @discardableResult
    internal func startSnapshotArchiveRepair(
        _ stream: XMPPStream,
        target: SnapshotRepairTarget,
        queryId: String? = nil,
        callback: (() -> Void)? = nil,
        requestCallbacks: RequestCallbacks = .none
    ) -> String? {
        guard target.conversationType.supportsSnapshotArchiveRepair,
              target.jid.isNotEmpty else {
            callback?()
            return nil
        }

        let pageSize = Self.regularArchivePageSize(requested: nil, defaultPageSize: self.pageSize)
        let newestLoadedArchiveId: String?
        do {
            let realm = try WRealm.safe()
            let primary = RegularChatArchiveSyncStateStorageItem.genPrimary(
                jid: target.jid,
                owner: self.owner,
                conversationType: target.conversationType
            )
            if let state = realm.object(ofType: RegularChatArchiveSyncStateStorageItem.self, forPrimaryKey: primary) {
                newestLoadedArchiveId = state.newestLoadedArchiveId
            } else {
                var loadedArchiveId: String?
                try realm.write {
                    let state = RegularChatArchiveSyncStateStorageItem.ensure(
                        owner: self.owner,
                        jid: target.jid,
                        conversationType: target.conversationType,
                        in: realm
                    )
                    loadedArchiveId = state.newestLoadedArchiveId
                }
                newestLoadedArchiveId = loadedArchiveId
            }
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
            callback?()
            return nil
        }

        let plan = Self.snapshotRepairRequestPlan(
            jid: target.jid,
            conversationType: target.conversationType,
            newestLoadedArchiveId: newestLoadedArchiveId,
            pageSize: pageSize
        )
        let requestQueryId = queryId ?? "MAM snapshot repair: \(NanoID.new(6))"
        return startRegularArchiveRequest(
            stream,
            plan: plan,
            queryId: requestQueryId,
            priority: .background,
            joinDuplicateRequests: true,
            callback: callback,
            requestCallbacks: requestCallbacks,
            deferCoverageCommitUntilConsumerProof: true
        )
    }

    private func startNextRegularIdleBackfillIfNeeded() {
        let attemptToken = withRegularIdleBackfillTriggerState {
            $0.beginScheduledAttempt()
        }
        guard let attemptToken else {
            return
        }

        let target: String?
        do {
            let realm = try WRealm.safe()
            let activeRegularJids = Set(
                regularArchiveInFlightByKey.keys
                    .filter { $0.conversationTypeRaw == ClientSynchronizationManager.ConversationType.regular.rawValue }
                    .map(\.jid)
            )
            target = realm.objects(LastChatsStorageItem.self)
                .filter("owner == %@ AND conversationType_ == %@ AND isSynced == false", self.owner, ClientSynchronizationManager.ConversationType.regular.rawValue)
                .sorted(byKeyPath: "messageDate", ascending: false)
                .first(where: { !activeRegularJids.contains($0.jid) })?
                .jid
        } catch {
            DDLogDebug("MessageArchiveManager: \(#function). \(error.localizedDescription)")
            finishRegularIdleBackfillAttempt(attemptToken)
            return
        }

        guard let jid = target else {
            finishRegularIdleBackfillAttempt(attemptToken)
            return
        }

        let pageSize = Self.regularArchivePageSize(requested: nil, defaultPageSize: self.pageSize)
        let queryId = "MAM idle regular bootstrap: \(NanoID.new(6))"
        let plan = Self.regularBootstrapRequestPlan(jid: jid, pageSize: pageSize)

        guard let account = AccountManager.shared.find(for: self.owner) else {
            self.finishRegularIdleBackfillAttempt(attemptToken)
            return
        }

        account.xmppTaskScheduler.enqueueAccountTask(
            priority: .idle,
            resource: .mamArchive,
            deduplicationKey: "regular.idle-bootstrap.\(self.owner)",
            requiresAuthenticatedStream: false
        ) { [weak self] user, stream, finish in
            guard let self else {
                finish()
                return
            }
            guard stream.isAuthenticated else {
                finish()
                self.finishRegularIdleBackfillAttempt(attemptToken)
                return
            }

            user.messages.beginArchiveQueryBatch(queryId: queryId)
            let completionLock = NSLock()
            var didReleaseWire = false
            var didFinishTransaction = false
            var wireEndPageToken: MessageArchiveEndPageDispatcher.Token?
            var failureToken: MessageArchiveRequestFailureDispatcher.Token?
            var preparationToken: MessageArchiveRequestFailurePreparationDispatcher.Token?
            var persistenceMustAbort = false
            var persistenceRequiresRetryAfterAbort = false
            var failureTerminalAcknowledgements: [() -> Void] = []
            let persistenceGate = ArchivePersistenceTerminalGate(
                timeout: self.archivePersistenceTerminalTimeout
            )

            let releaseWire = {
                completionLock.lock()
                guard !didReleaseWire else {
                    completionLock.unlock()
                    return
                }
                didReleaseWire = true
                completionLock.unlock()
                ChatArchiveDebugTrace.log("mamIdleBootstrapWireFin")
                finish()
            }
            let finishTransaction = { [weak self] (requiresRetry: Bool) in
                completionLock.lock()
                guard !didFinishTransaction else {
                    completionLock.unlock()
                    return
                }
                didFinishTransaction = true
                let activeWireEndPageToken = wireEndPageToken
                let activeFailureToken = failureToken
                let activePreparationToken = preparationToken
                let acknowledgements = failureTerminalAcknowledgements
                failureTerminalAcknowledgements.removeAll()
                completionLock.unlock()
                if let activeWireEndPageToken {
                    MessageArchiveEndPageDispatcher.unregister(activeWireEndPageToken)
                }
                if let activeFailureToken {
                    MessageArchiveRequestFailureDispatcher.unregister(activeFailureToken)
                }
                if let activePreparationToken {
                    MessageArchiveRequestFailurePreparationDispatcher.unregister(
                        activePreparationToken
                    )
                }
                acknowledgements.forEach { $0() }
                self?.finishRegularIdleBackfillAttempt(
                    attemptToken,
                    requiresRetry: requiresRetry
                )
            }

            let markPersistenceForAbort = {
                (requiresRetry: Bool, terminal: (() -> Void)?) in
                var acknowledgeImmediately = false
                completionLock.lock()
                if didFinishTransaction {
                    acknowledgeImmediately = terminal != nil
                } else {
                    persistenceMustAbort = true
                    persistenceRequiresRetryAfterAbort =
                        persistenceRequiresRetryAfterAbort || requiresRetry
                    if let terminal {
                        failureTerminalAcknowledgements.append(terminal)
                    }
                }
                completionLock.unlock()
                if acknowledgeImmediately {
                    terminal?()
                }
            }

            let flushPersistence = {
                guard persistenceGate.arm(onTimeout: {
                    user.mam.abortDeferredCommit(queryId: queryId)
                    ChatArchiveDebugTrace.log("mamIdleBootstrapPersistenceTimeout")
                    finishTransaction(true)
                }) else {
                    return
                }
                ChatArchiveDebugTrace.log("mamIdleBootstrapPersistenceStart")
                user.messages.finishArchiveQueryBatchAsync(queryId: queryId) { summary in
                    guard persistenceGate.claimPersistenceTerminal() else {
                        return
                    }
                    ChatArchiveDebugTrace.log("mamIdleBootstrapPersistenceTerminal", [
                        ("persistedRows", summary.persistedRows),
                        ("processedRows", summary.processedRows),
                        ("failedRows", summary.failed)
                    ])
                    completionLock.lock()
                    let mustAbort = persistenceMustAbort
                    let requiresRetryAfterAbort = persistenceRequiresRetryAfterAbort
                    completionLock.unlock()
                    if mustAbort {
                        user.mam.abortDeferredCommit(queryId: queryId)
                        finishTransaction(requiresRetryAfterAbort)
                        return
                    }

                    let commitResult = user.mam.commitAfterPersistence(
                        queryId: queryId,
                        persistenceSummary: summary
                    )
                    let requiresRetry: Bool
                    switch commitResult {
                    case .committed:
                        ChatArchiveDebugTrace.log("mamIdleBootstrapCommit")
                        requiresRetry = false
                    case .committedNeedsFollowUpRepair:
                        ChatArchiveDebugTrace.log("mamIdleBootstrapCommitNeedsRepair")
                        requiresRetry = true
                    case .missingDescriptor:
                        ChatArchiveDebugTrace.log("mamIdleBootstrapCommitMissingDescriptor")
                        requiresRetry = true
                    case .rejected(let rejection):
                        ChatArchiveDebugTrace.log("mamIdleBootstrapCommitFailed", [
                            ("failedRows", self.deferredArchiveFailedRowCount(rejection))
                        ])
                        requiresRetry = true
                    }
                    finishTransaction(requiresRetry)
                }
            }

            preparationToken = MessageArchiveRequestFailurePreparationDispatcher.register(
                owner: self.owner,
                queryId: queryId
            ) { _, terminal in
                releaseWire()
                markPersistenceForAbort(true, terminal)
                flushPersistence()
            }
            failureToken = MessageArchiveRequestFailureDispatcher.register(
                owner: self.owner,
                queryId: queryId,
                delivery: .synchronous
            ) { _ in
                releaseWire()
            }
            wireEndPageToken = MessageArchiveEndPageDispatcher.register(
                owner: self.owner,
                queryId: queryId,
                delivery: .synchronous
            ) { event in
                guard event.queryId == queryId else { return }
                releaseWire()
            }

            let startedQueryId = user.mam.startRegularArchiveRequest(
                stream,
                plan: plan,
                queryId: queryId,
                priority: .idle,
                callback: nil,
                requestCallbacks: RequestCallbacks(
                    onEndPage: { completedQueryId, _, _, _, _ in
                        guard completedQueryId == queryId else { return }
                        releaseWire()
                        flushPersistence()
                    },
                    onFailure: { event in
                        guard event.queryId == queryId else { return }
                        releaseWire()
                    }
                ),
                deferCoverageCommitUntilConsumerProof: true
            )
            if startedQueryId != queryId {
                // A higher-priority request for the same conversation won the
                // race after target selection. Do not attach this idle
                // persistence transaction to its query.
                releaseWire()
                markPersistenceForAbort(false, nil)
                flushPersistence()
            }
        }
    }
    
    internal func archiveRequestGenerationSnapshot() -> UInt64 {
        archiveRequestLifecycleLock.lock()
        defer { archiveRequestLifecycleLock.unlock() }
        return archiveRequestLifecycleGeneration
    }

    @discardableResult
    internal func didResetState(ifArchiveRequestGenerationMatches expectedGeneration: UInt64) -> Bool {
        archiveRequestLifecycleLock.lock()
        defer { archiveRequestLifecycleLock.unlock() }
        guard archiveRequestLifecycleGeneration == expectedGeneration else {
            return false
        }
        self.didResetState()
        return true
    }

    func didResetState() {
        archiveRequestLifecycleLock.lock()
        defer { archiveRequestLifecycleLock.unlock() }
        archiveRequestLifecycleGeneration &+= 1
        self.withRegularIdleBackfillTriggerState { $0.reset() }
        searchArchiveStateLock.lock()
        let activeSearchQueryIds = searchArchiveSessionsByQueryId.compactMap { queryId, session in
            session.isActive ? queryId : nil
        }
        searchArchiveStateLock.unlock()
        activeSearchQueryIds.forEach { _ = cancelSearch(queryId: $0) }
        let pendingItems = self.drainCallbackQueueItems()
        let pendingCallbacks = pendingItems.compactMap(\.callback)
        pendingItems.forEach { item in
            self.unregisterFallbackEndPageCallbacks(queryId: item.elementId)
            if let taskQueryId = item.task.queryId,
               taskQueryId != item.elementId {
                self.unregisterFallbackEndPageCallbacks(queryId: taskQueryId)
            }
        }
        self.queryIds.forEach { self.unregisterFallbackEndPageCallbacks(queryId: $0) }
        self.queryIds.removeAll()
        self.persistedMessageCountsByQueryId.removeAll()
        self.searchResultsQueries.removeAll()
        self.continuesTaskID = nil
        self.regularArchiveInFlightByKey.removeAll()
        self.regularArchiveRequestKeyByQueryId.removeAll()
        self.clearArchiveQueryPurposeRegistry()
        // Invoke callbacks after all old-session state has been cleared. A
        // synchronous callback may start a new-generation request; the
        // recursive lifecycle lock then lets it register without being erased
        // by the reset that triggered the callback.
        pendingCallbacks.forEach { $0() }
    }
}
