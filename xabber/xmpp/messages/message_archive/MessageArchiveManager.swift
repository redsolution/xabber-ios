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
    /// Raw MAM `<fin complete='…'>`; unlike `queryExhausted`, this is never
    /// inferred from a zero-sized page.
    let rawComplete: Bool
    /// Server RSM `<count>` as received. On Xabber Server this is the cheap
    /// page count unless the caller explicitly requested `rsm-counter=1`.
    let serverResultCount: Int?

    init(
        queryExhausted: Bool,
        archiveEnded: Bool,
        persistedMessageCount: Int,
        requestCursorId: String? = nil,
        rawComplete: Bool = false,
        serverResultCount: Int? = nil
    ) {
        self.queryExhausted = queryExhausted
        self.archiveEnded = archiveEnded
        self.persistedMessageCount = persistedMessageCount
        self.requestCursorId = requestCursorId
        self.rawComplete = rawComplete
        self.serverResultCount = serverResultCount
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

    /// Operation-scoped sampling keeps every lifecycle event for a selected
    /// transaction, instead of sampling unrelated individual log lines.
    @inline(__always)
    static func logOperation(
        _ event: @autoclosure () -> String,
        traceID: UInt64,
        _ fields: @autoclosure () -> [(String, Any?)] = []
    ) {
        #if DEBUG
        guard let sink = sinkForOperation(traceID: traceID) else {
            return
        }

        var parts = [
            "CHAT_ARCHIVE_TRACE",
            "event=\(sanitizedLabel(event(), fallback: "invalid-event"))",
            "thread=\(Thread.isMainThread ? "main" : "background")",
            "traceID=\(traceID)"
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

    private static func sinkForOperation(traceID: UInt64) -> Sink? {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        guard configuration.enabled,
              traceID.isMultiple(of: UInt64(configuration.sampleEvery)) else {
            return nil
        }
        return configuration.sink
    }

    private static func privacySafeValue(_ value: Any) -> String? {
        switch value {
        case let value as Bool:
            return value ? "true" : "false"
        case let value as Int:
            return String(value)
        case let value as UInt:
            return String(value)
        case let value as Int64:
            return String(value)
        case let value as UInt64:
            return String(value)
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

/// Arbitrates the only two legal terminals of a query-scoped persistence
/// flush. A late Realm callback after timeout is deliberately ignored.
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

class MessageArchiveManager: AbstractXMPPManager {

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

            return conversationType != .regular
        }
    }

    struct RequestCallbacks {
        let onMessage: ((MessageStorageItem, String) -> Void)?
        let onEndPage: ((String, MessageArchivePageEndState, String, String, Int) -> Void)?
        let onFailure: ((MessageArchiveRequestFailureEvent) -> Void)?

        init(
            onMessage: ((MessageStorageItem, String) -> Void)? = nil,
            onEndPage: ((String, MessageArchivePageEndState, String, String, Int) -> Void)? = nil,
            onFailure: ((MessageArchiveRequestFailureEvent) -> Void)? = nil
        ) {
            self.onMessage = onMessage
            self.onEndPage = onEndPage
            self.onFailure = onFailure
        }

        static let none = RequestCallbacks()
    }

    struct ArchivePageFinalDisposition: Equatable {
        let deliveredResultCount: Int
        let serverResultCount: Int?
        let queryExhausted: Bool
        let shouldContinue: Bool
    }

    static func archivePageFinalDisposition(
        deliveredResultCount: Int,
        serverResultCount: Int?,
        complete: Bool,
        requestedPageCursor: String?,
        responseLastCursor: String?
    ) -> ArchivePageFinalDisposition {
        let deliveredResultCount = max(0, deliveredResultCount)
        let responseLastCursor = responseLastCursor.flatMap {
            $0.isNotEmpty ? $0 : nil
        }
        let hasAdvancingCursor = responseLastCursor.map {
            $0 != requestedPageCursor
        } ?? false
        let queryExhausted = complete || deliveredResultCount == 0
        return ArchivePageFinalDisposition(
            deliveredResultCount: deliveredResultCount,
            serverResultCount: serverResultCount,
            queryExhausted: queryExhausted,
            shouldContinue: !queryExhausted && hasAdvancingCursor
        )
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
        case engineSearchPage
        case timestampLookup
        case latest
        case media
        case inviteRecovery

        var isArchiveHistoryProducing: Bool {
            switch self {
            case .bootstrap, .pageOlder, .pageNewer, .jump, .gapRepair:
                return true
            case .engineSearchPage, .timestampLookup, .latest, .media, .inviteRecovery:
                return false
            }
        }

        var routesMamServerErrorAsRequestFailure: Bool {
            switch self {
            case .bootstrap, .pageOlder, .pageNewer, .gapRepair, .engineSearchPage, .timestampLookup:
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

    private struct ArchiveDateConstraint {
        let start: Date?
        let shouldSkipRequest: Bool
    }

    static func newestBootstrapPageRequest(pageSize: Int) -> PageRequestConfiguration {
        PageRequestConfiguration(nextPage: "", prevPage: nil, max: pageSize)
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

    struct MAMRequestItem: Equatable, Hashable {
        let jid: String?
        let messageId: String?
        let conversationType: ClientSynchronizationManager.ConversationType
        let isContinues: Bool
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
        let retainsSealedTransportProofUntilBarrier: Bool
    }

    struct DeferredArchiveTransportProof {
        var deliveredResultCount: Int = 0
        var deliveredResultIds: Set<String> = []
        var deliveredResultsWithoutId: Int = 0
        var intentionallyConsumedResultIds: Set<String> = []
        var intentionallyConsumedResultsWithoutId: Int = 0
        var persistenceRoutedResultIds: Set<String> = []
        var persistenceRoutedResultsWithoutId: Int = 0

        var intentionallyConsumedResultCount: Int {
            intentionallyConsumedResultIds.count +
                intentionallyConsumedResultsWithoutId
        }

        mutating func record(resultId: String?) {
            guard let resultId,
                  resultId.isNotEmpty else {
                deliveredResultCount += 1
                deliveredResultsWithoutId += 1
                return
            }
            if deliveredResultIds.insert(resultId).inserted {
                deliveredResultCount += 1
            }
        }

        mutating func recordIntentionalConsumption(resultId: String?) {
            guard let resultId,
                  resultId.isNotEmpty else {
                guard persistenceRoutedResultsWithoutId == 0 else {
                    return
                }
                intentionallyConsumedResultsWithoutId += 1
                return
            }
            guard !persistenceRoutedResultIds.contains(resultId) else {
                return
            }
            intentionallyConsumedResultIds.insert(resultId)
        }

        mutating func recordPersistenceRouting(resultId: String?) {
            guard let resultId,
                  resultId.isNotEmpty else {
                persistenceRoutedResultsWithoutId += 1
                intentionallyConsumedResultsWithoutId = max(
                    0,
                    intentionallyConsumedResultsWithoutId - 1
                )
                return
            }
            persistenceRoutedResultIds.insert(resultId)
            intentionallyConsumedResultIds.remove(resultId)
        }
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

    private var callbacksQueue: Set<CallbackQueueItem> = Set<CallbackQueueItem>()
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
    public var isExtendedArchiveAvailable: Bool = false

    /// Auxiliary transports do not run the account's full service-discovery
    /// pipeline. Keep their MAM query capabilities aligned with the primary
    /// account before issuing conversation-type scoped requests.
    final func synchronizeArchiveCapabilities(from primaryManager: MessageArchiveManager?) {
        guard let primaryManager else { return }
        isExtendedArchiveAvailable = primaryManager.isExtendedArchiveAvailable
    }

    internal let pageSize: Int = ArchivePageSizing.history

    internal var searchResultsQueries: Set<String> = Set()

    private final class SchedulerCompletionGate {
        private let lock = NSLock()
        private var completion: (() -> Void)?

        init(_ completion: @escaping () -> Void) {
            self.completion = completion
        }

        func finish() {
            lock.lock()
            let completion = self.completion
            self.completion = nil
            lock.unlock()
            completion?()
        }
    }

    private var persistedMessageCountsByQueryId: [String: Int] = [:]
    private let deferredArchiveCommitLock = NSLock()
    private var deferredArchiveTransportProofsByQueryId: [String: DeferredArchiveTransportProof] = [:]
    private var sealedArchiveTransportProofsByQueryId: [String: DeferredArchiveTransportProof] = [:]
    private var sealedArchiveTransportProofOrder: [String] = []
    private var persistenceIngressExpectationsByQueryId: [String: Int] = [:]
    private var persistenceIngressExpectationOrder: [String] = []
    private let maximumDeferredArchiveCommitCount = 128
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
    override init(withOwner owner: String) {
        super.init(withOwner: owner)
    }

    private func completeCallback(_ callback: (() -> Void)?) {
        DispatchQueue.main.async {
            callback?()
        }
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

    /// An error response is never archive-boundary proof. Cross-stream MAM
    /// routing can outlive the manager instance that owns the callback queue,
    /// so retain the request-failure route independently and let the archive
    /// engine apply its retry policy.
    @discardableResult
    internal static func routeUnroutedRequestFailure(
        _ event: MessageArchiveRequestFailureEvent
    ) -> Bool {
        guard event.owner.isNotEmpty,
              event.queryId.isNotEmpty else {
            return false
        }

        let fallbackCallbacks = takeFallbackEndPageCallbacks(
            owner: event.owner,
            queryId: event.queryId
        )
        let fallbackFailure = fallbackCallbacks?.onFailure
        let failureDispatcherRegistered =
            MessageArchiveRequestFailureDispatcher.hasHandler(
                owner: event.owner,
                queryId: event.queryId
            )
        let prepared = MessageArchiveRequestFailurePreparationDispatcher.prepare(
            event
        ) {
            let delivered = MessageArchiveRequestFailureDispatcher.publish(event)
            if !delivered,
               let fallbackFailure {
                DispatchQueue.main.async {
                    fallbackFailure(event)
                }
            }
        }
        ChatArchiveDebugTrace.log("mamUnroutedRequestFailure", [
            ("streamKind", event.streamKind.rawValue),
            ("reason", event.reason.rawValue),
            ("prepared", prepared),
            ("failureDispatcherRegistered", failureDispatcherRegistered),
            ("fallbackFailureRegistered", fallbackFailure != nil)
        ])
        return prepared || failureDispatcherRegistered || fallbackFailure != nil
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
        }
    }

    internal func shouldPersistArchiveQueryId(_ queryId: String?) -> Bool {
        guard let queryId,
              queryId.isNotEmpty else {
            return false
        }
        archiveQueryPurposeLock.lock()
        let isActiveArchiveQuery =
            archiveQueryPurposeByQueryId[queryId]?.isArchiveHistoryProducing ??
            false
        archiveQueryPurposeLock.unlock()
        if isActiveArchiveQuery {
            return true
        }

        // A raw MAM `<fin>` is transport completion, not persistence
        // completion. MessageManager ingress may legitimately arrive after
        // the final IQ, so keep accepting the query identity while its
        // sealed transport proof or exact ingress budget is still retained.
        deferredArchiveCommitLock.lock()
        let isAwaitingPersistence =
            sealedArchiveTransportProofsByQueryId[queryId] != nil ||
            persistenceIngressExpectationsByQueryId[queryId] != nil
        deferredArchiveCommitLock.unlock()
        return isAwaitingPersistence
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
                $0.task.purpose == .engineSearchPage ||
                $0.task.purpose == .timestampLookup ||
                ($0.task.conversationType == .notifications && $0.task.purpose == .latest)
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
            _ = ChatArchivePerformanceTraceRegistry.shared.terminate(
                owner: self.owner,
                queryID: event.queryId,
                terminal: .failed
            )
            if item.task.purpose == .timestampLookup ||
                item.task.purpose == .engineSearchPage {
                self.notifyDidFailRequest(item.requestCallbacks, event: event)
            } else if item.task.conversationType == .notifications,
                      !item.task.purpose.isArchiveHistoryProducing {
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
        if fallbackItem.task.conversationType == .notifications {
            notifyDidFailRequest(
                fallbackItem.requestCallbacks,
                event: transaction.event
            )
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
            _ = ChatArchivePerformanceTraceRegistry.shared.terminate(
                owner: self.owner,
                queryID: queryId,
                terminal: .cancelled
            )
            self.removePendingArchiveRequestAfterFailure(item)
            return true
        }

        let hadState = self.queryIds.contains(queryId) ||
            self.shouldPersistArchiveQueryId(queryId)
        guard hadState else {
            return false
        }
        _ = ChatArchivePerformanceTraceRegistry.shared.terminate(
            owner: self.owner,
            queryID: queryId,
            terminal: .cancelled
        )
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
        self.unregisterArchiveQueryId(queryId)
        self.unregisterFallbackEndPageCallbacks(queryId: queryId)
        self.abortDeferredCommit(queryId: queryId)
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
        queryExhausted: Bool,
        rawComplete: Bool = false,
        serverResultCount: Int? = nil
    ) -> MessageArchivePageEndState {
        let persistedMessageCount = self.persistedMessageCountsByQueryId.removeValue(forKey: queryId) ?? 0
        return MessageArchivePageEndState(
            queryExhausted: queryExhausted,
            archiveEnded: queryExhausted,
            persistedMessageCount: persistedMessageCount,
            requestCursorId: task.messageId,
            rawComplete: rawComplete,
            serverResultCount: serverResultCount
        )
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

    internal static func unroutedRequestFailureEvent(
        owner: String,
        iq: XMPPIQ,
        streamKind: MessageArchiveEndPageEvent.StreamKind
    ) -> MessageArchiveRequestFailureEvent? {
        guard iq.iqType == .error,
              let elementId = iq.elementID else {
            return nil
        }
        return MessageArchiveRequestFailureEvent(
            owner: owner,
            queryId: elementId,
            streamKind: streamKind,
            reason: .serverError,
            errorDescription: mamErrorDescription(from: iq),
            pendingQueryCount: 1
        )
    }

    internal static func unroutedEndPageEvent(
        owner: String,
        iq: XMPPIQ,
        streamKind: MessageArchiveEndPageEvent.StreamKind
    ) -> MessageArchiveEndPageEvent? {
        guard iq.iqType == .result,
              let fin = mamFinalElement(in: iq),
              let queryId = fin.attributeStringValue(forName: "queryid"),
              let set = fin.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm") else {
            return nil
        }

        let complete = fin.attributeBoolValue(forName: "complete")
        guard let rawCount = set.element(forName: "count")?
                .stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let count = Int(rawCount),
              count >= 0 else {
            // Without the active manager's result ledger, omitted optional
            // RSM count is unknown rather than zero. Publishing a synthetic
            // zero here would let a teardown race claim confirmed-empty.
            return nil
        }
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
            let failureDispatcherRegistered = MessageArchiveRequestFailureDispatcher.hasHandler(
                owner: self.owner,
                queryId: elementId
            )
            let fallbackRegistered = Self.hasFallbackEndPageCallback(owner: self.owner, queryId: elementId)
            let localQueryRegistered = self.queryIds.contains(elementId)
            guard localCallbackRegistered ||
                    dispatcherRegistered ||
                    failureDispatcherRegistered ||
                    fallbackRegistered ||
                    localQueryRegistered else {
                return false
            }
            ChatArchiveDebugTrace.log("mamErrorReceived", [
                ("owner", self.owner),
                ("queryId", elementId),
                ("elementId", elementId),
                ("streamKind", streamKind.rawValue),
                ("localCallbackRegistered", localCallbackRegistered),
                ("dispatcherRegistered", dispatcherRegistered),
                ("failureDispatcherRegistered", failureDispatcherRegistered),
                ("fallbackRegistered", fallbackRegistered),
                ("localQueryRegistered", localQueryRegistered),
                ("route", localCallbackRegistered ? "activeLocalCallback" : "fallbackOrRegistered")
            ])
            if let item = self.firstCallbackQueueItem(where: { $0.elementId == elementId }) {
                let queryId = item.task.queryId ?? elementId
                _ = ChatArchivePerformanceTraceRegistry.shared.terminate(
                    owner: self.owner,
                    queryID: queryId,
                    terminal: .failed
                )
                let event = MessageArchiveRequestFailureEvent(
                    owner: self.owner,
                    queryId: queryId,
                    streamKind: streamKind,
                    reason: .serverError,
                    errorDescription: Self.mamErrorDescription(from: iq),
                    pendingQueryCount: 1
                )
                if item.task.purpose.isArchiveHistoryProducing {
                    self.beginPendingArchiveFailure(
                        item: item,
                        event: event,
                        terminal: {}
                    )
                    return true
                }
                self.notifyDidFailRequest(item.requestCallbacks, event: event)
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

            _ = ChatArchivePerformanceTraceRegistry.shared.terminate(
                owner: self.owner,
                queryID: elementId,
                terminal: .failed
            )
            let event = MessageArchiveRequestFailureEvent(
                owner: self.owner,
                queryId: elementId,
                streamKind: streamKind,
                reason: .serverError,
                errorDescription: Self.mamErrorDescription(from: iq),
                pendingQueryCount: 1
            )
            let failureRouted = Self.routeUnroutedRequestFailure(event)
            self.persistedMessageCountsByQueryId.removeValue(forKey: elementId)
            self.unregisterArchiveQueryId(elementId)
            self.queryIds.remove(elementId)
            ChatArchiveDebugTrace.log("mamOrphanErrorHandled", [
                ("localQueryRegistered", localQueryRegistered),
                ("failureRouted", failureRouted)
            ])
            return true
        }

        guard iq.iqType == .result,
              let elementId = iq.elementID,
              let fin = Self.mamFinalElement(in: iq),
              let queryId = fin.attributeStringValue(forName: "queryid") else {
            return false
        }
        guard let set = fin.element(forName: "set", xmlns: "http://jabber.org/protocol/rsm") else {
            _ = ChatArchivePerformanceTraceRegistry.shared.terminate(
                owner: self.owner,
                queryID: queryId,
                terminal: .failed
            )
            guard let item = self.firstCallbackQueueItem(where: {
                $0.elementId == elementId
            }) else {
                return false
            }
            let event = MessageArchiveRequestFailureEvent(
                owner: self.owner,
                queryId: item.task.queryId ?? queryId,
                streamKind: streamKind,
                reason: .malformedResponse,
                errorDescription: item.task.purpose == .engineSearchPage
                    ? "MAM search final is missing the RSM set"
                    : "MAM final is missing the RSM set",
                pendingQueryCount: 1
            )
            if item.task.purpose.isArchiveHistoryProducing {
                self.beginPendingArchiveFailure(
                    item: item,
                    event: event,
                    terminal: {}
                )
                return true
            } else {
                self.notifyDidFailRequest(item.requestCallbacks, event: event)
            }
            self.removePendingArchiveRequestAfterFailure(item)
            _ = MessageArchiveRequestFailureDispatcher.publish(event)
            return true
        }
        let complete = fin.attributeBoolValue(forName: "complete")
        let first = set.element(forName: "first")?.stringValue ?? ""
        let last = set.element(forName: "last")?.stringValue ?? ""
        // XEP-0059 makes `<count>` optional and defines it as cardinality of
        // the server result set, not the number of envelopes delivered in
        // this page. Keep it informational and use the wire ledger as the
        // compatibility count when the server omits it.
        let serverResultCount = set.element(forName: "count")?.stringValueAsNSInteger()
        let localCallbackRegistered = self.callbackQueueContains {
            $0.elementId == elementId
        }
        let dispatcherRegistered = MessageArchiveEndPageDispatcher.hasHandler(
            owner: self.owner,
            queryId: queryId
        )
        let fallbackRegistered = Self.hasFallbackEndPageCallback(
            owner: self.owner,
            queryId: queryId
        )
        let localQueryRegistered =
            self.queryIds.contains(elementId) ||
            self.queryIds.contains(queryId)
        guard localCallbackRegistered ||
                dispatcherRegistered ||
                fallbackRegistered ||
                localQueryRegistered else {
            ChatArchiveDebugTrace.log("mamFinalIgnoredNoActiveContext", [
                ("owner", self.owner),
                ("queryId", queryId),
                ("elementId", elementId),
                ("streamKind", streamKind.rawValue)
            ])
            return false
        }
        let transportProof =
            self.takeArchiveTransportProof(queryId: queryId) ??
            DeferredArchiveTransportProof()
        let deliveredResultCount = transportProof.deliveredResultCount
        _ = ChatArchivePerformanceTraceRegistry.shared.rawFinal(
            owner: self.owner,
            queryID: queryId,
            deliveredCount: deliveredResultCount
        )
        let resultCount = serverResultCount ?? deliveredResultCount
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
            ("serverResultCount", serverResultCount),
            ("deliveredResultCount", deliveredResultCount),
            ("complete", complete),
            ("first", first),
            ("last", last)
        ])
//        DispatchQueue.global().async {
            if let item = self.firstCallbackQueueItem(where: { $0.elementId == elementId }) {
                let nextPage = set.element(forName: "last")?.stringValue
                let pageDisposition = item.task.isContinues
                    ? Self.archivePageFinalDisposition(
                        deliveredResultCount: deliveredResultCount,
                        serverResultCount: serverResultCount,
                        complete: complete,
                        requestedPageCursor: item.task.nextPage,
                        responseLastCursor: nextPage
                    )
                    : ArchivePageFinalDisposition(
                        deliveredResultCount: deliveredResultCount,
                        serverResultCount: serverResultCount,
                        queryExhausted: deliveredResultCount == 0 || complete,
                        shouldContinue: false
                    )
                let pageEndState = self.makePageEndState(
                    for: item.task,
                    queryId: queryId,
                    queryExhausted: pageDisposition.queryExhausted,
                    rawComplete: complete,
                    serverResultCount: serverResultCount
                )
                if item.task.retainsSealedTransportProofUntilBarrier {
                    self.sealArchiveTransportProof(
                        queryId: queryId,
                        transportProof: transportProof
                    )
                }
                self.unregisterArchiveQueryId(queryId)
                self.removeCallbackQueueItem(item)
                self.queryIds.remove(elementId)
                self.notifyDidReceiveEndPage(
                    item.requestCallbacks,
                    queryId: queryId,
                    state: pageEndState,
                    first: first,
                    last: last,
                    count: pageDisposition.deliveredResultCount,
                    streamKind: streamKind
                )
                if item.task.isContinues,
                   pageDisposition.shouldContinue {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        self.requestNextArchivePage(
                            stream,
                            task: item.task,
                            nextPage: nextPage,
                            requestCallbacks: item.requestCallbacks,
                            callback: item.callback
                        )
                    }
                } else {
                    self.completeCallback(item.callback)
                }
            } else {
                // Keep orphan/fallback delivery on the same page-local count
                // contract as registered non-search callbacks.
                let count = deliveredResultCount
                let pageEndState = MessageArchivePageEndState(
                    queryExhausted: count == 0 || complete,
                    archiveEnded: count == 0 || complete,
                    persistedMessageCount: self.persistedMessageCountsByQueryId.removeValue(forKey: queryId) ?? 0,
                    requestCursorId: nil
                )
                if dispatcherRegistered ||
                    fallbackRegistered ||
                    localQueryRegistered {
                    sealArchiveTransportProof(
                        queryId: queryId,
                        transportProof: transportProof
                    )
                }
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

    @discardableResult
    public func scheduleMedia(
        jid: String?,
        conversationType: ClientSynchronizationManager.ConversationType,
        media: [MessageMediaAttachmentStorageItem.Kind],
        after lastMessageId: String?,
        requestCallbacks: RequestCallbacks = .none
    ) -> String? {
        guard let account = AccountManager.shared.find(for: owner) else { return nil }
        let queryId = "MAM attach: \(NanoID.new(8))"
        account.xmppTaskScheduler.enqueueAccountTask(
            priority: .background,
            resource: .mamArchive,
            deduplicationKey: "archive.media.\(owner).\(jid ?? "global").\(lastMessageId ?? "latest")",
            requiresAuthenticatedStream: true,
            unavailable: {
                requestCallbacks.onFailure?(
                    MessageArchiveRequestFailureEvent(
                        owner: account.jid,
                        queryId: queryId,
                        streamKind: .primary,
                        reason: .requestStartFailed,
                        errorDescription: "Media archive transport is unavailable",
                        pendingQueryCount: 1
                    )
                )
            }
        ) { user, stream, finish in
            let gate = SchedulerCompletionGate(finish)
            let callbacks = RequestCallbacks(
                onMessage: requestCallbacks.onMessage,
                onEndPage: { queryId, state, first, last, count in
                    gate.finish()
                    requestCallbacks.onEndPage?(queryId, state, first, last, count)
                },
                onFailure: { event in
                    gate.finish()
                    requestCallbacks.onFailure?(event)
                }
            )
            _ = user.mam.getMedia(
                stream,
                jid: jid,
                conversationType: conversationType,
                media: media,
                after: lastMessageId,
                queryId: queryId,
                requestCallbacks: callbacks
            )
        }
        return queryId
    }

    @discardableResult
    public func getMedia(_ stream: XMPPStream, jid: String?, conversationType: ClientSynchronizationManager.ConversationType, media: [MessageMediaAttachmentStorageItem.Kind], after lastMessageId: String?, queryId: String? = nil, requestCallbacks: RequestCallbacks = .none) -> String {
        let queryId = queryId ?? "MAM attach: \(NanoID.new(8))"
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
        return queryId
    }

    private func sealArchiveTransportProof(
        queryId: String,
        transportProof: DeferredArchiveTransportProof
    ) {
        guard queryId.isNotEmpty else {
            return
        }
        let expectedReceivedCount = max(
            0,
            transportProof.deliveredResultCount -
                transportProof.intentionallyConsumedResultCount
        )
        deferredArchiveCommitLock.lock()
        if sealedArchiveTransportProofsByQueryId[queryId] == nil {
            sealedArchiveTransportProofOrder.append(queryId)
        }
        sealedArchiveTransportProofsByQueryId[queryId] = transportProof
        if persistenceIngressExpectationsByQueryId[queryId] == nil {
            persistenceIngressExpectationOrder.append(queryId)
        }
        persistenceIngressExpectationsByQueryId[queryId] =
            expectedReceivedCount
        while persistenceIngressExpectationOrder.count >
                maximumDeferredArchiveCommitCount {
            let expiredQueryId = persistenceIngressExpectationOrder
                .removeFirst()
            persistenceIngressExpectationsByQueryId.removeValue(
                forKey: expiredQueryId
            )
        }
        while sealedArchiveTransportProofOrder.count > maximumDeferredArchiveCommitCount {
            let expiredQueryId = sealedArchiveTransportProofOrder.removeFirst()
            sealedArchiveTransportProofsByQueryId.removeValue(forKey: expiredQueryId)
        }
        deferredArchiveCommitLock.unlock()
    }

    /// Records the MAM result envelope before any consumer-specific routing.
    ///
    /// RSM `first`/`last` identify outer `<result id>` values. A marker,
    /// invite, call-control or other service stanza can therefore be a valid
    /// page boundary even though it intentionally never becomes a
    /// `MessageStorageItem`.
    @discardableResult
    internal func recordDeferredArchiveResultDelivery(
        _ message: XMPPMessage
    ) -> Bool {
        guard let result = message.element(forName: "result"),
              let queryId = result.attributeStringValue(forName: "queryid"),
              queryId.isNotEmpty,
              self.callbackQueueContains(where: { item in
                  (item.task.queryId ?? item.elementId) == queryId
              }) else {
            return false
        }

        deferredArchiveCommitLock.lock()
        var proof =
            deferredArchiveTransportProofsByQueryId[queryId] ??
            DeferredArchiveTransportProof()
        proof.record(resultId: result.attributeStringValue(forName: "id"))
        deferredArchiveTransportProofsByQueryId[queryId] = proof
        deferredArchiveCommitLock.unlock()
        return true
    }

    /// Acknowledges a result that a domain-specific consumer intentionally
    /// handled without routing it through `MessageManager` persistence.
    /// Deferred commit rejects any remaining unaccounted wire result.
    @discardableResult
    internal func recordDeferredArchiveControlConsumption(
        _ message: XMPPMessage
    ) -> Bool {
        guard let result = message.element(forName: "result"),
              let queryId = result.attributeStringValue(forName: "queryid"),
              queryId.isNotEmpty else {
            return false
        }

        deferredArchiveCommitLock.lock()
        guard var proof = deferredArchiveTransportProofsByQueryId[queryId] else {
            deferredArchiveCommitLock.unlock()
            return false
        }
        proof.recordIntentionalConsumption(
            resultId: result.attributeStringValue(forName: "id")
        )
        deferredArchiveTransportProofsByQueryId[queryId] = proof
        deferredArchiveCommitLock.unlock()
        return true
    }

    /// Records that at least one stream delegate routed the archive envelope
    /// into MessageManager. Persistence wins over a control-only disposition
    /// from another delegate regardless of callback order.
    @discardableResult
    internal func recordDeferredArchivePersistenceRouting(
        _ message: XMPPMessage
    ) -> Bool {
        guard let result = message.element(forName: "result"),
              let queryId = result.attributeStringValue(forName: "queryid"),
              queryId.isNotEmpty else {
            return false
        }

        deferredArchiveCommitLock.lock()
        guard var proof = deferredArchiveTransportProofsByQueryId[queryId] else {
            deferredArchiveCommitLock.unlock()
            return false
        }
        proof.recordPersistenceRouting(
            resultId: result.attributeStringValue(forName: "id")
        )
        deferredArchiveTransportProofsByQueryId[queryId] = proof
        deferredArchiveCommitLock.unlock()
        return true
    }

    private func takeArchiveTransportProof(
        queryId: String
    ) -> DeferredArchiveTransportProof? {
        guard queryId.isNotEmpty else { return nil }
        deferredArchiveCommitLock.lock()
        let proof = deferredArchiveTransportProofsByQueryId.removeValue(
            forKey: queryId
        )
        deferredArchiveCommitLock.unlock()
        return proof
    }

    /// Number of delivered result envelopes that must complete
    /// MessageManager ingress before query persistence can publish terminal.
    ///
    /// RSM `<count>` is whole-result-set cardinality and is intentionally not
    /// used here. Control envelopes explicitly consumed by another manager do
    /// not belong to MessageManager persistence.
    internal func expectedPersistenceResultCount(
        queryId: String
    ) -> Int? {
        guard queryId.isNotEmpty else {
            return nil
        }
        deferredArchiveCommitLock.lock()
        defer { deferredArchiveCommitLock.unlock() }
        if let proof = sealedArchiveTransportProofsByQueryId[queryId] {
            return max(
                0,
                proof.deliveredResultCount -
                    proof.intentionallyConsumedResultCount
            )
        }
        return persistenceIngressExpectationsByQueryId[queryId]
    }

    /// Immutable query-scoped wire ledger for the client archive engine.
    /// Realm/XMPP objects deliberately do not cross the engine actor boundary.
    struct ArchiveTransportAccountingSnapshot: Equatable {
        let resultArchiveIDs: [String]
        let deliveredResultCount: Int
        let intentionallyConsumedResultCount: Int
        let intentionallyConsumedArchiveIDs: Set<String>
    }

    internal func archiveTransportAccountingSnapshot(
        queryId: String
    ) -> ArchiveTransportAccountingSnapshot? {
        guard queryId.isNotEmpty else { return nil }
        deferredArchiveCommitLock.lock()
        defer { deferredArchiveCommitLock.unlock() }
        let proof = sealedArchiveTransportProofsByQueryId[queryId] ??
            deferredArchiveTransportProofsByQueryId[queryId]
        guard let proof else { return nil }
        var archiveIDs = Array(proof.deliveredResultIds)
        archiveIDs.append(
            contentsOf: Array(
                repeating: "",
                count: proof.deliveredResultsWithoutId
            )
        )
        return ArchiveTransportAccountingSnapshot(
            resultArchiveIDs: archiveIDs,
            deliveredResultCount: proof.deliveredResultCount,
            intentionallyConsumedResultCount: proof.intentionallyConsumedResultCount,
            intentionallyConsumedArchiveIDs:
                proof.intentionallyConsumedResultIds
        )
    }

    internal func abortDeferredCommit(queryId: String) {
        guard queryId.isNotEmpty else {
            return
        }
        deferredArchiveCommitLock.lock()
        deferredArchiveTransportProofsByQueryId.removeValue(forKey: queryId)
        sealedArchiveTransportProofsByQueryId.removeValue(forKey: queryId)
        sealedArchiveTransportProofOrder.removeAll { $0 == queryId }
        persistenceIngressExpectationsByQueryId.removeValue(forKey: queryId)
        persistenceIngressExpectationOrder.removeAll { $0 == queryId }
        deferredArchiveCommitLock.unlock()
    }

    internal func finishEngineSearchPage(queryId: String) {
        guard queryId.isNotEmpty else { return }
        searchResultsQueries.remove(queryId)
        persistedMessageCountsByQueryId.removeValue(forKey: queryId)
        unregisterFallbackEndPageCallbacks(queryId: queryId)
    }

    internal func requestArchive(_ stream: XMPPStream, jid: String?, isContinues: Bool, conversationType: ClientSynchronizationManager.ConversationType, purpose: RequestPurpose, queryId: String? = nil, searchText: String? = nil, ids: [String]? = nil, flipPage: Bool = true, before: String? = nil, beforeId: String? = nil, afterId: String? = nil, start: Date? = nil, end: Date? = nil, nextPage: String? = nil, prevPage: String? = nil, max: Int? = nil, tags: [Tags] = [], withCounter: Bool = false, retainSealedTransportProofUntilBarrier: Bool = false, callback: (() -> Void)? = nil, requestCallbacks: RequestCallbacks = .none) {
        let isGroupchat = [.group, .channel].contains(conversationType)
        // `rsm-counter=1` performs a full SQL COUNT on Xabber Server. Normal
        // archive orchestration only needs the cheap page count and must never
        // request the expensive counter implicitly.
        let requestsAuthoritativeCounter = withCounter
        let elementId = queryId ?? "MAM: \(NanoID.new(8))"
        let dateConstraint = self.archiveDateConstraint(
            conversationType: conversationType,
            requestedStart: start,
            requestedEnd: end
        )
        guard !dateConstraint.shouldSkipRequest else {
            _ = ChatArchivePerformanceTraceRegistry.shared.terminate(
                owner: self.owner,
                queryID: elementId,
                terminal: .cancelled
            )
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
        if requestsAuthoritativeCounter {
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
        let requestCursorId = (before ?? nextPage).flatMap { cursor in
            cursor.isNotEmpty ? cursor : nil
        }
        let task = MAMRequestItem(
            jid: jid,
            messageId: requestCursorId,
            conversationType: conversationType,
            isContinues: isContinues,
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
            retainsSealedTransportProofUntilBarrier:
                retainSealedTransportProofUntilBarrier
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
        _ = ChatArchivePerformanceTraceRegistry.shared.transportStarted(
            owner: self.owner,
            queryID: elementId
        )
        if isGroupchat {
            stream.send(XMPPIQ(iqType: .set, to: jid == nil ? nil : XMPPJID(string: jid ?? ""), elementID: elementId, child: query))
        } else {
            stream.send(XMPPIQ(iqType: .set, to: nil, elementID: elementId, child: query))
        }
    }

    private func requestNextArchivePage(
        _ stream: XMPPStream,
        task: MAMRequestItem,
        nextPage: String?,
        requestCallbacks: RequestCallbacks,
        callback: (() -> Void)?
    ) {
        guard let nextPage else {
            completeCallback(callback)
            return
        }
        requestArchive(
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
            retainSealedTransportProofUntilBarrier:
                task.retainsSealedTransportProofUntilBarrier,
            callback: callback,
            requestCallbacks: requestCallbacks
        )
    }

    @discardableResult
    public final func scheduleInviteRecovery(max: Int = 100) -> String? {
        guard isExtendedArchiveAvailable,
              let account = AccountManager.shared.find(for: owner) else {
            return nil
        }
        let queryId = "MAM invite recovery: \(NanoID.new(8))"
        account.xmppTaskScheduler.enqueueAccountTask(
            priority: .background,
            resource: .mamArchive,
            deduplicationKey: "archive.invite-recovery.\(owner)",
            requiresAuthenticatedStream: true
        ) { user, stream, finish in
            let gate = SchedulerCompletionGate(finish)
            let started = user.mam.requestInviteRecovery(
                stream,
                max: max,
                queryId: queryId,
                requestCallbacks: RequestCallbacks(
                    onEndPage: { _, _, _, _, _ in gate.finish() },
                    onFailure: { _ in gate.finish() }
                )
            )
            if started == nil {
                gate.finish()
            }
        }
        return queryId
    }

    @discardableResult
    public final func requestInviteRecovery(
        _ stream: XMPPStream,
        max: Int = 100,
        queryId: String? = nil,
        requestCallbacks: RequestCallbacks = .none
    ) -> String? {
        guard isExtendedArchiveAvailable else {
            return nil
        }
        let queryId = queryId ?? "MAM invite recovery: \(NanoID.new(8))"
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
            requestCallbacks: requestCallbacks
        )
        return queryId
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
                do {
                    let realm = try WRealm.safe()
                    let membership = realm.object(
                        ofType: GroupSelfMembershipStorageItem.self,
                        forPrimaryKey: GroupStorageKey.groupPrimary(
                            owner: owner,
                            groupJID: opponent
                        )
                    )
                    item.originalOutgoing = membership?.memberID == userId
                } catch {
                    DDLogDebug("MessageManager: \(#function). \(error.localizedDescription)")
                }
            } else {
                item.originalOutgoing = from == owner
            }

//            if item.originalOutgoing || item.state == .read {
//                item.isRead = true
            let readDate = item.readDate ??  nil
            if let readDate = readDate,
               item.date < readDate {
                item.isRead = true
            } else {
                item.isRead = item.state == .read
            }
            if parseSystemMessageMetadata(item.message, source: .mam) != nil {
                instance.configureSystemMessage(item.message,
                                                owner: owner,
                                                opponent: opponent,
                                                date: item.date,
                                                source: .mam)
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

            let requestCallbacks = self.firstCallbackQueueItem(where: {
                $0.elementId == queryId
            })?.requestCallbacks ?? .none
            self.notifyDidReceiveMessage(instance, queryId: queryId, callbacks: requestCallbacks)
        }
        return true
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
        let pendingItems = self.drainCallbackQueueItems()
        let pendingCallbacks = pendingItems.compactMap(\.callback)
        pendingItems.forEach { item in
            _ = ChatArchivePerformanceTraceRegistry.shared.terminate(
                owner: self.owner,
                queryID: item.task.queryId ?? item.elementId,
                terminal: .cancelled
            )
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
        self.deferredArchiveCommitLock.lock()
        // A raw `<fin>` transfers ownership from the stream session to the
        // query-scoped persistence transaction. Its sealed transport proof
        // and ingress expectation therefore survive a socket/module reset.
        // Only proofs for requests still on the wire belong to the discarded
        // session.
        self.deferredArchiveTransportProofsByQueryId.removeAll()
        self.deferredArchiveCommitLock.unlock()
        self.clearArchiveQueryPurposeRegistry()
        // Invoke callbacks after all old-session state has been cleared. A
        // synchronous callback may start a new-generation request; the
        // recursive lifecycle lock then lets it register without being erased
        // by the reset that triggered the callback.
        pendingCallbacks.forEach { $0() }
    }
}
