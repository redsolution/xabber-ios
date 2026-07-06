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
import Network
import XMPPFramework
import RealmSwift
import RxSwift
import RxCocoa
import SwiftKeychainWrapper
import UIKit
import MaterialComponents.MaterialPalettes

final class AccountXMPPTaskScheduler {
    enum Priority: Int, Comparable {
        case idle = 0
        case background = 1
        case foreground = 2
        case interactive = 3

        static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    enum Resource: Hashable {
        case mamArchive
        case vcard
        case avatar
        case other(String)
    }

    struct Configuration {
        let defaultMaxConcurrent: Int
        let maxConcurrentByResource: [Resource: Int]
        let defaultCooldown: TimeInterval
        let cooldownByResource: [Resource: TimeInterval]

        static let production = Configuration(
            defaultMaxConcurrent: 1,
            maxConcurrentByResource: [
                .mamArchive: 1,
                .vcard: 1,
                .avatar: 1,
            ],
            defaultCooldown: 0,
            cooldownByResource: [
                .mamArchive: 0.35,
                .vcard: 0.15,
                .avatar: 0.15,
            ]
        )

        static func test(
            defaultMaxConcurrent: Int = 1,
            maxConcurrentByResource: [Resource: Int] = [:],
            defaultCooldown: TimeInterval = 0,
            cooldowns: [Resource: TimeInterval] = [:]
        ) -> Configuration {
            Configuration(
                defaultMaxConcurrent: defaultMaxConcurrent,
                maxConcurrentByResource: maxConcurrentByResource,
                defaultCooldown: defaultCooldown,
                cooldownByResource: cooldowns
            )
        }

        func maxConcurrent(for resource: Resource) -> Int {
            max(maxConcurrentByResource[resource] ?? defaultMaxConcurrent, 1)
        }

        func cooldown(for resource: Resource) -> TimeInterval {
            max(cooldownByResource[resource] ?? defaultCooldown, 0)
        }
    }

    private struct ScheduledTask {
        let id: Int
        let priority: Priority
        let resource: Resource
        let deduplicationKey: String?
        let order: Int
        let work: (@escaping () -> Void) -> Void
    }

    private weak var account: Account?
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.xabber.account-xmpp-task-scheduler")
    private var pendingTasks: [ScheduledTask] = []
    private var runningCountByResource: [Resource: Int] = [:]
    private var delayedResources: Set<Resource> = []
    private var runningDeduplicationKeys: Set<String> = []
    private var nextTaskID: Int = 0
    private var nextOrder: Int = 0
    private var isPaused: Bool
    private let bootstrapGate: () -> Bool

    init(
        account: Account? = nil,
        configuration: Configuration = .production,
        startsImmediately: Bool = true,
        bootstrapGate: @escaping () -> Bool = { false }
    ) {
        self.account = account
        self.configuration = configuration
        self.isPaused = !startsImmediately
        self.bootstrapGate = bootstrapGate
    }

    func enqueue(
        priority: Priority,
        resource: Resource,
        deduplicationKey: String?,
        work: @escaping (@escaping () -> Void) -> Void
    ) {
        queue.async {
            if let deduplicationKey {
                if self.runningDeduplicationKeys.contains(deduplicationKey) {
                    return
                }
                if let index = self.pendingTasks.firstIndex(where: { $0.deduplicationKey == deduplicationKey }) {
                    guard priority > self.pendingTasks[index].priority else {
                        return
                    }
                    let existing = self.pendingTasks[index]
                    self.pendingTasks[index] = ScheduledTask(
                        id: existing.id,
                        priority: priority,
                        resource: resource,
                        deduplicationKey: deduplicationKey,
                        order: existing.order,
                        work: work
                    )
                    self.drainLocked()
                    return
                }
            }

            let task = ScheduledTask(
                id: self.nextTaskID,
                priority: priority,
                resource: resource,
                deduplicationKey: deduplicationKey,
                order: self.nextOrder,
                work: work
            )
            self.nextTaskID += 1
            self.nextOrder += 1
            self.pendingTasks.append(task)
            self.drainLocked()
        }
    }

    func enqueueAccountTask(
        priority: Priority,
        resource: Resource,
        deduplicationKey: String?,
        requiresAuthenticatedStream: Bool = true,
        work: @escaping (Account, XMPPStream, @escaping () -> Void) -> Void
    ) {
        enqueue(priority: priority, resource: resource, deduplicationKey: deduplicationKey) { [weak self] finish in
            guard let self, let account = self.account else {
                finish()
                return
            }
            account.action { user, stream in
                guard !requiresAuthenticatedStream || user.sendReadiness.snapshot.canFlushApplicationStanzas else {
                    finish()
                    return
                }
                work(user, stream, finish)
            }
        }
    }

    func resume() {
        queue.async {
            self.isPaused = false
            self.drainLocked()
        }
    }

    func bootstrapGateDidChange() {
        queue.async {
            self.drainLocked()
        }
    }

    func reset() {
        queue.async {
            self.pendingTasks.removeAll()
            self.runningCountByResource.removeAll()
            self.runningDeduplicationKeys.removeAll()
            self.delayedResources.removeAll()
        }
    }

    private func drainLocked() {
        guard !isPaused else {
            return
        }

        while let index = nextRunnableTaskIndexLocked() {
            let task = pendingTasks.remove(at: index)
            runningCountByResource[task.resource, default: 0] += 1
            if let deduplicationKey = task.deduplicationKey {
                runningDeduplicationKeys.insert(deduplicationKey)
            }

            let completion = makeCompletion(for: task)
            task.work(completion)
        }
    }

    private func nextRunnableTaskIndexLocked() -> Int? {
        pendingTasks
            .enumerated()
            .filter { _, task in
                !delayedResources.contains(task.resource)
                    && runningCountByResource[task.resource, default: 0] < configuration.maxConcurrent(for: task.resource)
                    && (!bootstrapGate() || task.priority == .interactive)
            }
            .max { lhs, rhs in
                if lhs.element.priority == rhs.element.priority {
                    return lhs.element.order > rhs.element.order
                }
                return lhs.element.priority < rhs.element.priority
            }?
            .offset
    }

    private func makeCompletion(for task: ScheduledTask) -> () -> Void {
        let completionLock = NSLock()
        var didComplete = false

        return { [weak self] in
            completionLock.lock()
            guard !didComplete else {
                completionLock.unlock()
                return
            }
            didComplete = true
            completionLock.unlock()

            self?.complete(task)
        }
    }

    private func complete(_ task: ScheduledTask) {
        queue.async {
            self.runningCountByResource[task.resource] = max(self.runningCountByResource[task.resource, default: 1] - 1, 0)
            if self.runningCountByResource[task.resource] == 0 {
                self.runningCountByResource.removeValue(forKey: task.resource)
            }
            if let deduplicationKey = task.deduplicationKey {
                self.runningDeduplicationKeys.remove(deduplicationKey)
            }

            let cooldown = self.configuration.cooldown(for: task.resource)
            if cooldown > 0 {
                self.delayedResources.insert(task.resource)
                self.queue.asyncAfter(deadline: .now() + cooldown) {
                    self.delayedResources.remove(task.resource)
                    self.drainLocked()
                }
            } else {
                self.drainLocked()
            }
        }
    }
}

enum AccountStreamLifecyclePhase: String {
    case idle
    case connecting
    case tlsNegotiating
    case authenticating
    case binding
    case postAuthSetup
    case online
    case disconnecting
    case failed

    var allowsNewConnect: Bool {
        switch self {
        case .idle, .failed:
            return true
        case .connecting, .tlsNegotiating, .authenticating, .binding, .postAuthSetup, .online, .disconnecting:
            return false
        }
    }

    var allowsTimeoutRetry: Bool {
        switch self {
        case .connecting, .tlsNegotiating:
            return true
        case .idle, .authenticating, .binding, .postAuthSetup, .online, .disconnecting, .failed:
            return false
        }
    }

    var isConnectionDiagnosticsHeartbeatActive: Bool {
        switch self {
        case .connecting, .tlsNegotiating, .authenticating, .binding, .postAuthSetup:
            return true
        case .idle, .online, .disconnecting, .failed:
            return false
        }
    }
}

enum AccountConnectTrigger: String {
    case initialLoad
    case addExistingAccount
    case restore
    case statusUpdate
    case resourceUpdate
    case timeoutRetry
    case xmppReconnect
    case pathRecovery
    case livenessProbe
    case resilienceRetry
    case deviceReregister
    case legacyDirect
    case uiActionOpen
    case uiActionRestore
    case uiActionPerformRequest
}

enum AccountStreamConnectDecision: Equatable {
    case start(attemptID: UInt64)
    case skip(phase: AccountStreamLifecyclePhase, activeAttemptID: UInt64?)
}

enum AccountStreamConnectPreflightSkipReason: String {
    case frameworkActive
    case gateActive
}

enum AccountStreamConnectPreflightDecision: Equatable {
    case start(attemptID: UInt64, stalePhase: AccountStreamLifecyclePhase?)
    case skip(
        phase: AccountStreamLifecyclePhase,
        activeAttemptID: UInt64?,
        reason: AccountStreamConnectPreflightSkipReason
    )
}

struct AccountStreamConnectPreflight {
    static func decide(
        gate: AccountStreamLifecycleGate,
        trigger: AccountConnectTrigger,
        forceReset: Bool,
        frameworkActivePhase: AccountStreamLifecyclePhase?,
        streamIsDisconnected: Bool
    ) -> AccountStreamConnectPreflightDecision {
        if !forceReset, let frameworkActivePhase {
            gate.adoptFrameworkActivePhase(frameworkActivePhase)
            let snapshot = gate.snapshot()
            return .skip(
                phase: snapshot.phase,
                activeAttemptID: snapshot.activeAttemptID,
                reason: .frameworkActive
            )
        }

        let stalePhase = forceReset || !streamIsDisconnected
            ? nil
            : gate.resetIfBlockedByDisconnectedStream()

        switch gate.beginConnect(trigger: trigger, force: forceReset) {
        case .start(let attemptID):
            return .start(attemptID: attemptID, stalePhase: stalePhase)

        case .skip(let phase, let activeAttemptID):
            return .skip(
                phase: phase,
                activeAttemptID: activeAttemptID,
                reason: .gateActive
            )
        }
    }
}

enum AccountForegroundConnectionRecoveryDecision: Equatable {
    case skip
    case requestImmediateReconnect
    case waitForActiveAttempt
}

enum AccountForegroundConnectionRecoveryPolicy {
    static func decide(
        canFlushApplicationStanzas: Bool,
        lifecyclePhase: AccountStreamLifecyclePhase,
        isNetworkPathSatisfied: Bool?
    ) -> AccountForegroundConnectionRecoveryDecision {
        guard !canFlushApplicationStanzas else {
            return .skip
        }
        guard isNetworkPathSatisfied != false else {
            return .skip
        }

        switch lifecyclePhase {
        case .idle, .failed:
            return .requestImmediateReconnect
        case .connecting, .tlsNegotiating, .authenticating, .binding, .postAuthSetup:
            return .waitForActiveAttempt
        case .online, .disconnecting:
            return .skip
        }
    }
}

final class AccountStreamLifecycleGate {
    private let lock = NSLock()
    private var nextAttemptID: UInt64 = 0
    private(set) var phase: AccountStreamLifecyclePhase = .idle
    private(set) var activeAttemptID: UInt64?

    func beginConnect(trigger: AccountConnectTrigger, force: Bool = false) -> AccountStreamConnectDecision {
        lock.lock()
        defer { lock.unlock() }

        if force {
            phase = .idle
            activeAttemptID = nil
        }

        guard phase.allowsNewConnect else {
            return .skip(phase: phase, activeAttemptID: activeAttemptID)
        }

        nextAttemptID += 1
        activeAttemptID = nextAttemptID
        phase = .connecting
        return .start(attemptID: nextAttemptID)
    }

    func adoptFrameworkActivePhase(_ phase: AccountStreamLifecyclePhase) {
        lock.lock()
        defer { lock.unlock() }

        guard self.phase.allowsNewConnect else { return }
        self.phase = phase
    }

    func markTLSNegotiating() {
        transition(to: .tlsNegotiating, allowedFrom: [.connecting])
    }

    func markAuthenticating() {
        transition(to: .authenticating, allowedFrom: [.connecting, .tlsNegotiating])
    }

    func markBinding() {
        transition(to: .binding, allowedFrom: [.authenticating, .tlsNegotiating, .connecting])
    }

    func markPostAuthSetup() {
        transition(to: .postAuthSetup, allowedFrom: [.binding, .authenticating, .tlsNegotiating, .connecting])
    }

    func markOnline() {
        transition(to: .online, allowedFrom: [.postAuthSetup, .binding, .authenticating])
    }

    func markDisconnecting() {
        lock.lock()
        phase = .disconnecting
        lock.unlock()
    }

    func markDisconnected() {
        lock.lock()
        phase = .idle
        activeAttemptID = nil
        lock.unlock()
    }

    func resetIfBlockedByDisconnectedStream() -> AccountStreamLifecyclePhase? {
        lock.lock()
        defer { lock.unlock() }

        guard !phase.allowsNewConnect else { return nil }

        let stalePhase = phase
        phase = .idle
        activeAttemptID = nil
        return stalePhase
    }

    func markFailed() {
        lock.lock()
        phase = .failed
        activeAttemptID = nil
        lock.unlock()
    }

    func reset() {
        lock.lock()
        phase = .idle
        activeAttemptID = nil
        lock.unlock()
    }

    func canRetryTimeout(for attemptID: UInt64?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let attemptID, attemptID != activeAttemptID {
            return false
        }
        return phase.allowsTimeoutRetry
    }

    func snapshot() -> (phase: AccountStreamLifecyclePhase, activeAttemptID: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        return (phase, activeAttemptID)
    }

    private func transition(to newPhase: AccountStreamLifecyclePhase, allowedFrom: Set<AccountStreamLifecyclePhase>) {
        lock.lock()
        if allowedFrom.contains(phase) {
            phase = newPhase
        }
        lock.unlock()
    }
}

enum AccountDisconnectCause: String, Equatable {
    case intentionalShutdown
    case accountDeletion
    case resourceUpdate
    case backgroundSuspension
    case accidentalSocket
    case pingTimeout
    case bindingTimeout
    case retryableAuthFailure
    case permanentAuthFailure
    case serverStreamError

    var isIntentional: Bool {
        switch self {
        case .intentionalShutdown, .accountDeletion, .resourceUpdate, .backgroundSuspension, .permanentAuthFailure:
            return true
        case .accidentalSocket, .pingTimeout, .bindingTimeout, .retryableAuthFailure, .serverStreamError:
            return false
        }
    }

    var allowsAutoReconnect: Bool {
        !isIntentional
    }
}

enum AccountNetworkPathStatus: String, Equatable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

enum AccountNetworkInterface: String, Hashable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case other
}

struct AccountNetworkPathSnapshot: Equatable {
    let status: AccountNetworkPathStatus
    let interfaces: Set<AccountNetworkInterface>
    let isExpensive: Bool
    let isConstrained: Bool

    init(
        status: AccountNetworkPathStatus,
        interfaces: Set<AccountNetworkInterface> = [],
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.status = status
        self.interfaces = interfaces
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    var isSatisfied: Bool {
        status == .satisfied
    }

    static func from(_ path: NWPath) -> AccountNetworkPathSnapshot {
        let status: AccountNetworkPathStatus
        switch path.status {
        case .satisfied:
            status = .satisfied
        case .requiresConnection:
            status = .requiresConnection
        case .unsatisfied:
            status = .unsatisfied
        @unknown default:
            status = .unsatisfied
        }

        var interfaces = Set<AccountNetworkInterface>()
        if path.usesInterfaceType(.wifi) {
            interfaces.insert(.wifi)
        }
        if path.usesInterfaceType(.cellular) {
            interfaces.insert(.cellular)
        }
        if path.usesInterfaceType(.wiredEthernet) {
            interfaces.insert(.wiredEthernet)
        }
        if path.usesInterfaceType(.loopback) {
            interfaces.insert(.loopback)
        }
        if path.usesInterfaceType(.other) {
            interfaces.insert(.other)
        }

        return AccountNetworkPathSnapshot(
            status: status,
            interfaces: interfaces,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}

protocol AccountNetworkPathMonitoring: AnyObject {
    var pathUpdateHandler: ((AccountNetworkPathSnapshot) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func cancel()
}

final class AccountNWPathMonitor: AccountNetworkPathMonitoring {
    private let monitor = NWPathMonitor()
    var pathUpdateHandler: ((AccountNetworkPathSnapshot) -> Void)?

    func start(queue: DispatchQueue) {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathUpdateHandler?(AccountNetworkPathSnapshot.from(path))
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }
}

protocol AccountConnectionResilienceCancellable: AnyObject {
    func cancel()
}

protocol AccountConnectionResilienceScheduling: AnyObject {
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> AccountConnectionResilienceCancellable
}

private final class DispatchAccountConnectionResilienceCancellable: AccountConnectionResilienceCancellable {
    private let item: DispatchWorkItem

    init(item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

final class DispatchAccountConnectionResilienceScheduler: AccountConnectionResilienceScheduling {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> AccountConnectionResilienceCancellable {
        let item = DispatchWorkItem(block: block)
        queue.asyncAfter(deadline: .now() + max(delay, 0), execute: item)
        return DispatchAccountConnectionResilienceCancellable(item: item)
    }
}

enum XMPPStreamTLSTrustEvaluator {
    static func evaluate(_ trust: SecTrust, peerName: String?) -> Bool {
        let name = peerName?.isEmpty == false ? peerName : nil
        let policy = SecPolicyCreateSSL(true, name.map { $0 as CFString })
        _ = SecTrustSetPolicies(trust, policy)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}

struct AccountConnectionResiliencePolicy {
    let pingInterval: TimeInterval
    let pingTimeout: TimeInterval
    let maxMissedPings: Int
    let staleActivityTimeout: TimeInterval
    let pathDebounce: TimeInterval
    let stableOnlineReset: TimeInterval
    let reconnectBaseDelay: TimeInterval
    let reconnectMaxDelay: TimeInterval
    let jitterRatio: Double
    let fastResumeDelays: [TimeInterval]
    let outboundConfirmationTimeout: TimeInterval
    let bindingSetupTimeout: TimeInterval
    let jitter: () -> Double

    static func aggressive(jitter: @escaping () -> Double = { Double.random(in: -1...1) }) -> AccountConnectionResiliencePolicy {
        AccountConnectionResiliencePolicy(
            pingInterval: 15,
            pingTimeout: 8,
            maxMissedPings: 1,
            staleActivityTimeout: 40,
            pathDebounce: 0.75,
            stableOnlineReset: 60,
            reconnectBaseDelay: 2,
            reconnectMaxDelay: 60,
            jitterRatio: 0.2,
            fastResumeDelays: [0, 1],
            outboundConfirmationTimeout: 8,
            bindingSetupTimeout: 8,
            jitter: jitter
        )
    }
}

enum AccountConnectionStaleReason: String, Equatable {
    case noConfirmedTraffic
    case pingTimeout
    case outboundConfirmationTimeout
    case primaryStreamAckTimeout
    case primaryStreamTrackingLimit
    case bindingTimeout
}

struct AccountConnectionHealthSnapshot: Equatable {
    let lastInboundStanzaAt: TimeInterval?
    let lastStreamManagementAckAt: TimeInterval?
    let lastDeliveryReceiptAt: TimeInterval?
    let lastSuccessfulPingAt: TimeInterval?
    let lastOutboundStanzaAt: TimeInterval?
    let pendingOutgoingCount: Int
    let lastConfirmedActivityAt: TimeInterval?
    let lastActivityAge: TimeInterval?
    let isSuspectedStale: Bool
    let suspectedStaleReason: AccountConnectionStaleReason?
    let isNetworkPathSatisfied: Bool?
}

struct AccountConnectionResilienceActions {
    let sendPing: () -> Bool
    let forceClose: (AccountDisconnectCause) -> Void
    let requestReconnect: (AccountConnectTrigger, AccountDisconnectCause) -> Bool
    let probeOnlineStream: () -> Void
    let canResumeStream: () -> Bool
    let skipFullSetupAfterResume: () -> Void
    let runFullSetupAfterAuthentication: () -> Void
    let invalidateEndpointResolutionCache: (String) -> Void
    let markSuspectedStale: (AccountConnectionStaleReason, AccountConnectionHealthSnapshot) -> Void
    let healthChanged: (AccountConnectionHealthSnapshot) -> Void
    let log: (String, [String: Any?]) -> Void
}

final class AccountConnectionResilienceCoordinator {
    private let policy: AccountConnectionResiliencePolicy
    private let scheduler: AccountConnectionResilienceScheduling
    private let actions: AccountConnectionResilienceActions
    private let stateLock = NSRecursiveLock()

    private var isForegroundActive = false
    private var isOnline = false
    private var currentPath: AccountNetworkPathSnapshot?
    private var pendingPing = false
    private var missedPings = 0
    private var retryAttempt = 0
    private var fastResumeAttempt = 0
    private var lastActivityAt: TimeInterval?
    private var lastInboundStanzaAt: TimeInterval?
    private var lastStreamManagementAckAt: TimeInterval?
    private var lastDeliveryReceiptAt: TimeInterval?
    private var lastSuccessfulPingAt: TimeInterval?
    private var lastOutboundStanzaAt: TimeInterval?
    private var pendingOutgoingCount = 0
    private var isSuspectedStale = false
    private var suspectedStaleReason: AccountConnectionStaleReason?
    private var livenessTimer: AccountConnectionResilienceCancellable?
    private var pingTimeoutTimer: AccountConnectionResilienceCancellable?
    private var outboundConfirmationTimer: AccountConnectionResilienceCancellable?
    private var retryTimer: AccountConnectionResilienceCancellable?
    private var pathDebounceTimer: AccountConnectionResilienceCancellable?
    private var stableOnlineTimer: AccountConnectionResilienceCancellable?
    private var bindingWatchdogTimer: AccountConnectionResilienceCancellable?
    private var pausedReconnect: (cause: AccountDisconnectCause, trigger: AccountConnectTrigger)?

    var healthSnapshot: AccountConnectionHealthSnapshot {
        withStateLock {
            makeHealthSnapshot(now: scheduler.now)
        }
    }

    init(
        policy: AccountConnectionResiliencePolicy = .aggressive(),
        scheduler: AccountConnectionResilienceScheduling,
        actions: AccountConnectionResilienceActions
    ) {
        self.policy = policy
        self.scheduler = scheduler
        self.actions = actions
    }

    func setForegroundActive(_ active: Bool) {
        withStateLock {
            setForegroundActiveLocked(active)
        }
    }

    private func setForegroundActiveLocked(_ active: Bool) {
        isForegroundActive = active
        actions.log(
            active ? "resilience_foreground_active" : "resilience_foreground_inactive",
            ["online": isOnline]
        )
        if active {
            actions.invalidateEndpointResolutionCache("foreground-active")
            scheduleLivenessTick()
        } else {
            cancelLiveness()
            cancelBindingWatchdog(reason: "foreground-inactive")
        }
    }

    func streamDidReachOnline(resumed: Bool) {
        withStateLock {
            streamDidReachOnlineLocked(resumed: resumed)
        }
    }

    private func streamDidReachOnlineLocked(resumed: Bool) {
        cancelBindingWatchdog(reason: "stream-online")
        isOnline = true
        pendingPing = false
        missedPings = 0
        isSuspectedStale = false
        suspectedStaleReason = nil
        recordConfirmedActivity(reason: resumed ? "stream-management-resumed" : "stream-online", kind: .inboundStanza)
        cancelRetry()
        scheduleStableOnlineReset()
        scheduleLivenessTick()
        actions.log(
            "resilience_stream_online",
            ["resumed": resumed]
        )
    }

    func streamDidDisconnect(cause: AccountDisconnectCause) {
        withStateLock {
            streamDidDisconnectLocked(cause: cause)
        }
    }

    private func streamDidDisconnectLocked(cause: AccountDisconnectCause) {
        cancelBindingWatchdog(reason: "stream-disconnected")
        isOnline = false
        pendingPing = false
        missedPings = 0
        lastActivityAt = nil
        cancelLiveness()
        outboundConfirmationTimer?.cancel()
        outboundConfirmationTimer = nil
        stableOnlineTimer?.cancel()
        stableOnlineTimer = nil
        actions.log(
            "resilience_stream_disconnected",
            ["cause": cause.rawValue, "willReconnect": cause.allowsAutoReconnect]
        )
        guard cause.allowsAutoReconnect else {
            cancelRetry()
            pausedReconnect = nil
            return
        }
        scheduleReconnect(cause: cause, trigger: .resilienceRetry)
    }

    func streamDidEnterBinding() {
        withStateLock {
            streamDidEnterBindingLocked()
        }
    }

    func streamDidLeaveBinding(reason: String) {
        withStateLock {
            cancelBindingWatchdog(reason: reason)
        }
    }

    private func streamDidEnterBindingLocked() {
        guard isForegroundActive, !isOnline, !isSuspectedStale, currentPath?.isSatisfied ?? true else {
            actions.log(
                "resilience_binding_watchdog_skipped",
                [
                    "foreground": isForegroundActive,
                    "online": isOnline,
                    "suspectedStale": isSuspectedStale,
                    "pathSatisfied": currentPath?.isSatisfied
                ]
            )
            return
        }

        bindingWatchdogTimer?.cancel()
        actions.log(
            "resilience_binding_watchdog_started",
            ["timeout": policy.bindingSetupTimeout]
        )
        bindingWatchdogTimer = scheduler.schedule(after: policy.bindingSetupTimeout) { [weak self] in
            self?.withStateLock {
                self?.handleBindingTimeout()
            }
        }
    }

    func noteInboundActivity(_ reason: String) {
        withStateLock {
            recordConfirmedActivity(reason: reason, kind: .inboundStanza)
            scheduleLivenessTick()
        }
    }

    func noteStreamManagementAck() {
        withStateLock {
            recordConfirmedActivity(reason: "stream-management-ack", kind: .streamManagementAck)
            scheduleLivenessTick()
        }
    }

    func noteDeliveryReceipt(originId: String, stanzaId: String) {
        withStateLock {
            recordConfirmedActivity(reason: "delivery-receipt", kind: .deliveryReceipt)
            actions.log(
                "resilience_delivery_receipt_observed",
                ["originId": originId, "stanzaId": stanzaId]
            )
            scheduleLivenessTick()
        }
    }

    func noteOutboundApplicationStanza(id: String?) {
        withStateLock {
            lastOutboundStanzaAt = scheduler.now
            publishHealthSnapshot()
            actions.log(
                "resilience_outbound_stanza_observed",
                ["id": id ?? "none", "timeout": policy.outboundConfirmationTimeout]
            )
            scheduleOutboundConfirmationTimeout()
        }
    }

    func notePrimaryStreamAckTimeout(stanzaId: String?, generation: UInt64) {
        withStateLock {
            guard isOnline, !isSuspectedStale else {
                actions.log(
                    "resilience_primary_stream_ack_timeout_ignored",
                    ["id": stanzaId ?? "none", "generation": generation, "online": isOnline]
                )
                return
            }
            actions.log(
                "resilience_primary_stream_ack_timeout",
                ["id": stanzaId ?? "none", "generation": generation]
            )
            forceCloseAfterLivenessFailure(reason: .primaryStreamAckTimeout)
        }
    }

    func notePrimaryStreamTrackingLimitRejected(_ violation: PrimaryStreamTrackingLimitViolation) {
        withStateLock {
            actions.log(
                "resilience_primary_stream_tracking_limit_rejected",
                ["violation": String(describing: violation), "online": isOnline]
            )
            guard isOnline, !isSuspectedStale else { return }
            forceCloseAfterLivenessFailure(reason: .primaryStreamTrackingLimit)
        }
    }

    func updatePendingOutgoingCount(_ count: Int) {
        withStateLock {
            pendingOutgoingCount = max(0, count)
            publishHealthSnapshot()
        }
    }

    func notePingResult(success: Bool) {
        withStateLock {
            actions.log(
                success ? "resilience_ping_result" : "resilience_ping_error",
                ["success": success]
            )
            if success {
                recordConfirmedActivity(reason: "ping-result", kind: .successfulPing)
                scheduleLivenessTick()
            } else {
                handlePingTimeout()
            }
        }
    }

    func networkPathDidChange(_ snapshot: AccountNetworkPathSnapshot) {
        withStateLock {
            pathDebounceTimer?.cancel()
            pathDebounceTimer = scheduler.schedule(after: policy.pathDebounce) { [weak self] in
                self?.withStateLock {
                    self?.applyNetworkPath(snapshot)
                }
            }
        }
    }

    func streamManagementResumeCompleted(didResume: Bool, responseName: String?) {
        withStateLock {
            actions.log(
                didResume ? "stream_management_resume_succeeded" : "stream_management_resume_failed",
                ["response": responseName ?? "none"]
            )
            if didResume {
                actions.skipFullSetupAfterResume()
            } else {
                actions.runFullSetupAfterAuthentication()
            }
            streamDidReachOnlineLocked(resumed: didResume)
        }
    }

    func scheduleReconnect(cause: AccountDisconnectCause, trigger: AccountConnectTrigger) {
        withStateLock {
            scheduleReconnectLocked(cause: cause, trigger: trigger)
        }
    }

    func requestImmediateReconnect(cause: AccountDisconnectCause, trigger: AccountConnectTrigger) {
        withStateLock {
            scheduleReconnectLocked(
                cause: cause,
                trigger: trigger,
                delayOverride: 0,
                replaceExistingRetry: true
            )
        }
    }

    private func scheduleReconnectLocked(
        cause: AccountDisconnectCause,
        trigger: AccountConnectTrigger,
        delayOverride: TimeInterval? = nil,
        replaceExistingRetry: Bool = false
    ) {
        guard cause.allowsAutoReconnect else { return }
        if replaceExistingRetry {
            retryTimer?.cancel()
            retryTimer = nil
        }
        guard retryTimer == nil else { return }
        guard currentPath?.isSatisfied ?? true else {
            pausedReconnect = (cause, trigger)
            actions.log(
                "resilience_reconnect_paused_path_unsatisfied",
                ["cause": cause.rawValue, "trigger": trigger.rawValue]
            )
            return
        }

        let delay = delayOverride ?? reconnectDelay()
        actions.log(
            "resilience_reconnect_scheduled",
            ["cause": cause.rawValue, "trigger": trigger.rawValue, "delay": delay]
        )
        retryTimer = scheduler.schedule(after: delay) { [weak self] in
            self?.withStateLock {
                self?.fireReconnect(cause: cause, trigger: trigger)
            }
        }
    }

    private func applyNetworkPath(_ snapshot: AccountNetworkPathSnapshot) {
        let previous = currentPath
        currentPath = snapshot
        if let previous, previous != snapshot {
            actions.invalidateEndpointResolutionCache("path-changed")
        }
        actions.log(
            "resilience_path_changed",
            [
                "status": snapshot.status.rawValue,
                "interfaces": snapshot.interfaces.map(\.rawValue).sorted().joined(separator: ","),
                "isExpensive": snapshot.isExpensive,
                "isConstrained": snapshot.isConstrained
            ]
        )

        guard snapshot.isSatisfied else {
            cancelLiveness()
            cancelBindingWatchdog(reason: "path-unsatisfied")
            return
        }

        let recovered = previous?.isSatisfied == false
        let interfaceChanged = previous != nil && previous?.interfaces != snapshot.interfaces
        guard recovered || interfaceChanged else { return }

        if isOnline {
            actions.probeOnlineStream()
            sendLivenessProbeNow()
        } else if let pausedReconnect {
            self.pausedReconnect = nil
            scheduleReconnectLocked(
                cause: pausedReconnect.cause,
                trigger: .pathRecovery,
                delayOverride: 0,
                replaceExistingRetry: true
            )
        } else {
            scheduleReconnectLocked(
                cause: .accidentalSocket,
                trigger: .pathRecovery,
                delayOverride: 0,
                replaceExistingRetry: true
            )
        }
    }

    private func scheduleLivenessTick() {
        guard isForegroundActive, isOnline, !isSuspectedStale, currentPath?.isSatisfied ?? true else { return }
        livenessTimer?.cancel()
        livenessTimer = scheduler.schedule(after: policy.pingInterval) { [weak self] in
            self?.withStateLock {
                self?.sendLivenessProbeNow()
            }
        }
    }

    private func sendLivenessProbeNow() {
        guard isForegroundActive, isOnline, !isSuspectedStale, currentPath?.isSatisfied ?? true else { return }
        guard !pendingPing else { return }

        if let lastActivityAt,
           scheduler.now - lastActivityAt >= policy.staleActivityTimeout {
            actions.log(
                "resilience_liveness_stale_activity",
                ["age": scheduler.now - lastActivityAt]
            )
            forceCloseAfterLivenessFailure(reason: .noConfirmedTraffic)
            return
        }

        pendingPing = true
        actions.log("resilience_ping_enqueue", ["timeout": policy.pingTimeout])
        guard actions.sendPing() else {
            handlePingTimeout()
            return
        }
        pingTimeoutTimer?.cancel()
        pingTimeoutTimer = scheduler.schedule(after: policy.pingTimeout) { [weak self] in
            self?.withStateLock {
                self?.handlePingTimeout()
            }
        }
    }

    private func handlePingTimeout() {
        guard pendingPing, isOnline, !isSuspectedStale else { return }
        pendingPing = false
        pingTimeoutTimer?.cancel()
        pingTimeoutTimer = nil
        missedPings += 1
        actions.log(
            "resilience_ping_timeout",
            ["missedPings": missedPings, "limit": policy.maxMissedPings]
        )

        guard missedPings >= policy.maxMissedPings else {
            scheduleLivenessTick()
            return
        }
        forceCloseAfterLivenessFailure(reason: .pingTimeout)
    }

    private func handleBindingTimeout() {
        bindingWatchdogTimer?.cancel()
        bindingWatchdogTimer = nil
        guard isForegroundActive, !isOnline, !isSuspectedStale, currentPath?.isSatisfied ?? true else {
            actions.log(
                "resilience_binding_timeout_ignored",
                [
                    "foreground": isForegroundActive,
                    "online": isOnline,
                    "suspectedStale": isSuspectedStale,
                    "pathSatisfied": currentPath?.isSatisfied
                ]
            )
            return
        }

        actions.log(
            "resilience_binding_timeout",
            ["timeout": policy.bindingSetupTimeout]
        )
        cancelLiveness()
        markSuspectedStale(.bindingTimeout)
        isOnline = false
        actions.forceClose(.bindingTimeout)
        scheduleReconnectLocked(
            cause: .bindingTimeout,
            trigger: .resilienceRetry,
            delayOverride: 0,
            replaceExistingRetry: true
        )
    }

    private func forceCloseAfterLivenessFailure(reason: AccountConnectionStaleReason) {
        cancelLiveness()
        markSuspectedStale(reason)
        isOnline = false
        actions.forceClose(.pingTimeout)
        scheduleReconnectLocked(
            cause: .pingTimeout,
            trigger: .resilienceRetry,
            delayOverride: 0,
            replaceExistingRetry: true
        )
    }

    private func scheduleOutboundConfirmationTimeout() {
        guard isForegroundActive, isOnline, !isSuspectedStale else { return }
        outboundConfirmationTimer?.cancel()
        outboundConfirmationTimer = scheduler.schedule(after: policy.outboundConfirmationTimeout) { [weak self] in
            self?.withStateLock {
                self?.handleOutboundConfirmationTimeout()
            }
        }
    }

    private func handleOutboundConfirmationTimeout() {
        guard isOnline, !isSuspectedStale else { return }
        actions.log(
            "resilience_outbound_confirmation_timeout",
            ["timeout": policy.outboundConfirmationTimeout]
        )
        forceCloseAfterLivenessFailure(reason: .outboundConfirmationTimeout)
    }

    private func fireReconnect(cause: AccountDisconnectCause, trigger: AccountConnectTrigger) {
        retryTimer = nil
        guard currentPath?.isSatisfied ?? true else {
            pausedReconnect = (cause, trigger)
            actions.log(
                "resilience_reconnect_paused_path_unsatisfied",
                ["cause": cause.rawValue, "trigger": trigger.rawValue]
            )
            return
        }
        let started = actions.requestReconnect(trigger, cause)
        actions.log(
            started ? "resilience_reconnect_started" : "resilience_reconnect_skipped",
            ["cause": cause.rawValue, "trigger": trigger.rawValue]
        )
    }

    private func reconnectDelay() -> TimeInterval {
        if actions.canResumeStream(), fastResumeAttempt < policy.fastResumeDelays.count {
            let delay = policy.fastResumeDelays[fastResumeAttempt]
            fastResumeAttempt += 1
            return delay
        }

        let exponent = min(retryAttempt, 10)
        retryAttempt += 1
        let base = min(policy.reconnectMaxDelay, policy.reconnectBaseDelay * pow(2, Double(exponent)))
        let boundedJitter = max(-1, min(1, policy.jitter()))
        return max(0, base + (base * policy.jitterRatio * boundedJitter))
    }

    private func scheduleStableOnlineReset() {
        stableOnlineTimer?.cancel()
        stableOnlineTimer = scheduler.schedule(after: policy.stableOnlineReset) { [weak self] in
            self?.withStateLock {
                self?.retryAttempt = 0
                self?.fastResumeAttempt = 0
                self?.actions.log("resilience_backoff_reset", [:])
            }
        }
    }

    private func cancelLiveness() {
        livenessTimer?.cancel()
        livenessTimer = nil
        pingTimeoutTimer?.cancel()
        pingTimeoutTimer = nil
        outboundConfirmationTimer?.cancel()
        outboundConfirmationTimer = nil
        pendingPing = false
    }

    private func cancelRetry() {
        retryTimer?.cancel()
        retryTimer = nil
        pausedReconnect = nil
    }

    private func cancelBindingWatchdog(reason: String) {
        guard bindingWatchdogTimer != nil else { return }
        bindingWatchdogTimer?.cancel()
        bindingWatchdogTimer = nil
        actions.log("resilience_binding_watchdog_cancelled", ["reason": reason])
    }

    private enum ConfirmedActivityKind {
        case inboundStanza
        case streamManagementAck
        case deliveryReceipt
        case successfulPing
    }

    @discardableResult
    private func withStateLock<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    private func recordConfirmedActivity(reason: String, kind: ConfirmedActivityKind) {
        guard !isSuspectedStale else {
            actions.log("resilience_activity_ignored_after_stale", ["reason": reason])
            return
        }

        let now = scheduler.now
        lastActivityAt = now
        switch kind {
        case .inboundStanza:
            lastInboundStanzaAt = now
        case .streamManagementAck:
            lastStreamManagementAckAt = now
        case .deliveryReceipt:
            lastDeliveryReceiptAt = now
        case .successfulPing:
            lastSuccessfulPingAt = now
        }
        pendingPing = false
        missedPings = 0
        pingTimeoutTimer?.cancel()
        pingTimeoutTimer = nil
        outboundConfirmationTimer?.cancel()
        outboundConfirmationTimer = nil
        actions.log(
            "resilience_activity_observed",
            ["reason": reason]
        )
        publishHealthSnapshot()
    }

    private func markSuspectedStale(_ reason: AccountConnectionStaleReason) {
        guard !isSuspectedStale else { return }
        isSuspectedStale = true
        suspectedStaleReason = reason
        let snapshot = makeHealthSnapshot(now: scheduler.now)
        actions.log(
            "connection_health_suspected_stale",
            ["reason": reason.rawValue, "lastActivityAge": snapshot.lastActivityAge]
        )
        actions.healthChanged(snapshot)
        actions.markSuspectedStale(reason, snapshot)
    }

    private func publishHealthSnapshot() {
        actions.healthChanged(makeHealthSnapshot(now: scheduler.now))
    }

    private func makeHealthSnapshot(now: TimeInterval) -> AccountConnectionHealthSnapshot {
        AccountConnectionHealthSnapshot(
            lastInboundStanzaAt: lastInboundStanzaAt,
            lastStreamManagementAckAt: lastStreamManagementAckAt,
            lastDeliveryReceiptAt: lastDeliveryReceiptAt,
            lastSuccessfulPingAt: lastSuccessfulPingAt,
            lastOutboundStanzaAt: lastOutboundStanzaAt,
            pendingOutgoingCount: pendingOutgoingCount,
            lastConfirmedActivityAt: lastActivityAt,
            lastActivityAge: lastActivityAt.map { max(0, now - $0) },
            isSuspectedStale: isSuspectedStale,
            suspectedStaleReason: suspectedStaleReason,
            isNetworkPathSatisfied: currentPath?.isSatisfied
        )
    }
}

enum AccountSendReadinessReadyKind: String, Equatable {
    case streamManagementEnabled
    case streamManagementResumed
}

enum AccountSendReadinessPhase: Equatable {
    case disconnected
    case connecting
    case tlsNegotiating
    case authenticating
    case binding
    case enablingStreamManagement
    case resuming
    case ready(AccountSendReadinessReadyKind)
    case suspectedStale
    case backgroundSuspended
    case streamError
    case streamManagementFailed

    var canFlushApplicationStanzas: Bool {
        if case .ready = self {
            return true
        }
        return false
    }
}

struct AccountSendReadinessSnapshot: Equatable {
    let phase: AccountSendReadinessPhase
    let updatedAt: Date
    let reason: String?

    var canFlushApplicationStanzas: Bool {
        phase.canFlushApplicationStanzas
    }
}

final class AccountSendReadinessCoordinator {
    private let lock = NSRecursiveLock()
    private var currentSnapshot: AccountSendReadinessSnapshot
    var snapshot: AccountSendReadinessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return currentSnapshot
    }
    var onReadinessChanged: ((AccountSendReadinessSnapshot) -> Void)?

    init(initialDate: Date = Date()) {
        self.currentSnapshot = AccountSendReadinessSnapshot(
            phase: .disconnected,
            updatedAt: initialDate,
            reason: nil
        )
    }

    func markConnecting(trigger: AccountConnectTrigger) {
        transition(to: .connecting, reason: trigger.rawValue)
    }

    func markTLSNegotiating() {
        transition(to: .tlsNegotiating)
    }

    func markAuthenticating() {
        transition(to: .authenticating)
    }

    func markBinding() {
        transition(to: .binding)
    }

    func markStreamManagementEnableRequested() {
        transition(to: .enablingStreamManagement)
    }

    func markResuming() {
        transition(to: .resuming)
    }

    func markStreamManagementEnabled() {
        transition(to: .ready(.streamManagementEnabled))
    }

    func markStreamManagementResumeSucceeded() {
        transition(to: .ready(.streamManagementResumed))
    }

    func markStreamManagementResumeFailed(reason: String? = nil) {
        transition(to: .enablingStreamManagement, reason: reason)
    }

    func markStreamManagementEnableFailed(reason: String? = nil) {
        transition(to: .streamManagementFailed, reason: reason)
    }

    func markSuspectedStale(reason: String? = nil) {
        transition(to: .suspectedStale, reason: reason)
    }

    func markDisconnected(cause: AccountDisconnectCause) {
        if cause == .backgroundSuspension {
            transition(to: .backgroundSuspended, reason: cause.rawValue)
        } else {
            transition(to: .disconnected, reason: cause.rawValue)
        }
    }

    func markStreamError(_ reason: String? = nil) {
        transition(to: .streamError, reason: reason)
    }

    private func transition(to phase: AccountSendReadinessPhase, reason: String? = nil) {
        let nextSnapshot = AccountSendReadinessSnapshot(
            phase: phase,
            updatedAt: Date(),
            reason: reason
        )
        lock.lock()
        currentSnapshot = nextSnapshot
        let callback = onReadinessChanged
        lock.unlock()
        callback?(nextSnapshot)
    }
}

struct AccountQueuedMessageSendRequest {
    let owner: String
    let conversationJid: String
    let conversationType: ClientSynchronizationManager.ConversationType
    let messagePrimary: String
    let originId: String
    let stanzaXML: String
    let createdAt: Date
    let replayRequired: Bool
}

final class AccountSendCoordinator {
    static let deliveryReceiptTimeoutErrorCode = "delivery-receipt-timeout"
    static let deliveryReceiptTimeoutErrorMessage = "Request timeout".localizeString(
        id: "message_manager_errpr_request_timeout",
        arguments: []
    )

    struct Environment {
        let owner: String
        let isSendReady: () -> Bool
        let sendReadinessSnapshot: () -> AccountSendReadinessSnapshot?
        let decorateMessage: (XMPPMessage, Bool, Bool) -> XMPPMessage
        let sendMessage: (XMPPMessage) -> Void
        let updatePendingOutgoingCount: (Int) -> Void
        let scheduler: AccountConnectionResilienceScheduling
        let receiptTimeout: TimeInterval
        let now: () -> Date
        let log: (String, [String: Any?]) -> Void

        init(
            owner: String,
            isSendReady: @escaping () -> Bool,
            sendReadinessSnapshot: @escaping () -> AccountSendReadinessSnapshot? = { nil },
            decorateMessage: @escaping (XMPPMessage, Bool, Bool) -> XMPPMessage,
            sendMessage: @escaping (XMPPMessage) -> Void,
            updatePendingOutgoingCount: @escaping (Int) -> Void = { _ in },
            scheduler: AccountConnectionResilienceScheduling = DispatchAccountConnectionResilienceScheduler(
                queue: DispatchQueue(label: "com.xabber.account.send-coordinator.receipt-timeout")
            ),
            receiptTimeout: TimeInterval = 5,
            now: @escaping () -> Date = { Date() },
            log: @escaping (String, [String: Any?]) -> Void
        ) {
            self.owner = owner
            self.isSendReady = isSendReady
            self.sendReadinessSnapshot = sendReadinessSnapshot
            self.decorateMessage = decorateMessage
            self.sendMessage = sendMessage
            self.updatePendingOutgoingCount = updatePendingOutgoingCount
            self.scheduler = scheduler
            self.receiptTimeout = receiptTimeout
            self.now = now
            self.log = log
        }
    }

    private struct SendCandidate {
        let queuePrimary: String
        let originId: String
        let stanzaXML: String
        let replayRequired: Bool
        let missRetryElement: Bool
        let attemptCount: Int
    }

    private struct ReceiptTimeoutRegistration {
        let id: String
        let attemptCount: Int
        let cancellable: AccountConnectionResilienceCancellable
    }

    private let environment: Environment
    private let receiptTimeoutLock = DispatchQueue(label: "com.xabber.account.send-coordinator.receipt-timeout-lock")
    private var receiptTimeouts: [String: ReceiptTimeoutRegistration] = [:]

    init(environment: Environment) {
        self.environment = environment
    }

    convenience init(account: Account) {
        self.init(
            environment: Environment(
                owner: account.jid,
                isSendReady: { [weak account] in
                    account?.sendReadiness.snapshot.canFlushApplicationStanzas ?? false
                },
                sendReadinessSnapshot: { [weak account] in
                    account?.sendReadiness.snapshot
                },
                decorateMessage: { [weak account] message, retry, missRetryElement in
                    guard let account else { return message }
                    message.addChild(account.chatMarkers.child)
                    return account.deliveryManager.apply(
                        to: message,
                        retry: retry,
                        missRetryElement: missRetryElement
                    )
                },
                sendMessage: { [weak account] message in
                    guard let account else { return }
                    let originId = PrimaryStreamStanzaIdentifier.ensureID(on: message)
                    let result = account.sendPrimaryStanza(
                        message,
                        replayPolicy: .durableRegularMessage(originId: originId)
                    )
                    if case .rejected(let violation) = result {
                        let error = NSError(
                            domain: "AccountPrimaryStreamStanzaTracker",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "primary stream stanza tracking rejected: \(violation)"
                            ]
                        )
                        _ = account.sendCoordinator.localSendFailed(message: message, error: error)
                    }
                },
                updatePendingOutgoingCount: { [weak account] count in
                    account?.connectionResilience.updatePendingOutgoingCount(count)
                },
                log: { [weak account] event, details in
                    account?.logConnectionDiagnostics(event: event, details: details)
                }
            )
        )
    }

    @discardableResult
    func enqueueRegularMessage(_ request: AccountQueuedMessageSendRequest) throws -> Bool {
        let didPersist = try AccountSendCoordinator.persistRegularMessage(request)
        if didPersist {
            environment.log(
                "account_send_coordinator_message_enqueued",
                queueDiagnostics([
                    "originId": request.originId,
                    "messagePrimary": request.messagePrimary,
                    "conversationJid": request.conversationJid,
                    "conversationType": request.conversationType.rawValue
                ])
            )
            notifyPendingOutgoingCount()
            drainReadyQueue()
        }
        return didPersist
    }

    @discardableResult
    func deletePendingOutgoingMessage(primary: String) -> Bool {
        do {
            guard let result = try PendingOutgoingMessageDeletionStore.delete(primary: primary, owner: environment.owner) else {
                return false
            }
            result.queuePrimaries.forEach {
                cancelReceiptTimeout(queuePrimary: $0)
            }
            notifyPendingOutgoingCount()
            drainNextReadyMessage(conversationJid: result.conversationJid, conversationType: result.conversationType)
            environment.log(
                "account_send_coordinator_pending_message_deleted",
                queueDiagnostics([
                    "messagePrimary": result.messagePrimary,
                    "deletedQueueCount": result.queuePrimaries.count
                ])
            )
            return true
        } catch {
            DDLogDebug("AccountSendCoordinator: deletePendingOutgoingMessage failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func persistRegularMessage(_ request: AccountQueuedMessageSendRequest) throws -> Bool {
        guard request.conversationType == .regular else {
            return false
        }

        let realm = try WRealm.safe()
        let primary = OutgoingMessageQueueItem.genPrimary(
            owner: request.owner,
            conversationJid: request.conversationJid,
            conversationType: request.conversationType,
            messagePrimary: request.messagePrimary
        )
        let existing = realm.object(ofType: OutgoingMessageQueueItem.self, forPrimaryKey: primary)
        let isTerminalRetry = existing?.state == .terminalFailed
        if existing != nil,
           !isTerminalRetry {
            return false
        }
        try realm.write {
            let item = existing ?? OutgoingMessageQueueItem()
            item.configure(
                owner: request.owner,
                conversationJid: request.conversationJid,
                conversationType: request.conversationType,
                messagePrimary: request.messagePrimary,
                originId: request.originId,
                stanzaXML: request.stanzaXML,
                createdAt: request.createdAt,
                replayRequired: request.replayRequired
            )
            if isTerminalRetry,
               let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: request.messagePrimary) {
                message.state = .sending
                message.messageError = nil
                message.messageErrorCode = nil
                message.references.forEach {
                    $0.hasError = false
                }
                realm.object(
                    ofType: LastChatsStorageItem.self,
                    forPrimaryKey: LastChatsStorageItem.genPrimary(
                        jid: message.opponent,
                        owner: message.owner,
                        conversationType: message.conversationType
                    )
                )?.hasErrorInChat = false
            }
            realm.add(item, update: .modified)
        }
        return true
    }

    static func restoreRecoverableRegularMessages(owner: String) {
        do {
            let realm = try WRealm.safe()
            let messages = realm
                .objects(MessageStorageItem.self)
                .filter(
                    "owner == %@ AND outgoing == true AND conversationType_ == %@ AND messageType == %@ AND state_ == %@",
                    owner,
                    ClientSynchronizationManager.ConversationType.regular.rawValue,
                    MessageStorageItem.MessageDisplayType.text.rawValue,
                    MessageStorageItem.MessageSendingState.sending.rawValue
                )
            guard !messages.isEmpty else { return }
            try realm.write {
                messages.forEach { message in
                    guard let storedStanza = realm.object(
                        ofType: MessageStanzaStorageItem.self,
                        forPrimaryKey: [message.primary, "_stanza"].joined()
                    ), storedStanza.stanza.isNotEmpty else {
                        return
                    }
                    let primary = OutgoingMessageQueueItem.genPrimary(
                        owner: message.owner,
                        conversationJid: message.opponent,
                        conversationType: message.conversationType,
                        messagePrimary: message.primary
                    )
                    guard realm.object(ofType: OutgoingMessageQueueItem.self, forPrimaryKey: primary) == nil else {
                        return
                    }
                    let item = OutgoingMessageQueueItem()
                    item.configure(
                        owner: message.owner,
                        conversationJid: message.opponent,
                        conversationType: message.conversationType,
                        messagePrimary: message.primary,
                        originId: message.messageId,
                        stanzaXML: storedStanza.stanza,
                        createdAt: message.date,
                        replayRequired: false
                    )
                    realm.add(item, update: .modified)
                }
            }
        } catch {
            DDLogDebug("AccountSendCoordinator: restoreRecoverableRegularMessages failed: \(error.localizedDescription)")
        }
    }

    func accountDidBecomeSendReady() {
        AccountSendCoordinator.restoreRecoverableRegularMessages(owner: environment.owner)
        notifyPendingOutgoingCount()
        rescheduleAwaitingReceiptTimeouts()
        environment.log(
            "account_send_coordinator_ready_drain_requested",
            queueDiagnostics([:])
        )
        drainReadyQueue()
    }

    func streamDidDisconnect(canResume: Bool) {
        cancelAllReceiptTimeouts()
        environment.log(
            "account_send_coordinator_stream_disconnected",
            queueDiagnostics(["canResume": canResume])
        )
    }

    func streamManagementResumeSucceeded() {
        rescheduleAwaitingReceiptTimeouts()
        environment.log(
            "account_send_coordinator_resume_succeeded_drain_requested",
            queueDiagnostics([:])
        )
        drainReadyQueue()
    }

    func streamManagementResumeFailed() {
        do {
            cancelAllReceiptTimeouts()
            let realm = try WRealm.safe()
            let awaiting = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter(
                    "owner == %@ AND state_ == %@",
                    environment.owner,
                    OutgoingMessageQueueItem.State.awaitingReceipt.rawValue
                )
            guard !awaiting.isEmpty else { return }
            let awaitingItems = Array(awaiting)
            try realm.write {
                awaitingItems.forEach { item in
                    if let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.messagePrimary),
                       message.archivedId.isNotEmpty || message.state != .sending {
                        realm.delete(item)
                    } else {
                        item.state = .queued
                        item.replayRequired = true
                        item.lastError = "stream-management-resume-failed"
                    }
                }
            }
            notifyPendingOutgoingCount()
            environment.log(
                "account_send_coordinator_resume_failed_requeued",
                queueDiagnostics(["count": awaitingItems.count])
            )
        } catch {
            DDLogDebug("AccountSendCoordinator: streamManagementResumeFailed failed: \(error.localizedDescription)")
        }
    }

    func deliveryReceiptReceived(originId: String, stanzaId: String) {
        do {
            let realm = try WRealm.safe()
            let completedItems = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter("owner == %@ AND originId == %@", environment.owner, originId)
            let completed = Array(completedItems)
            let chatKeys = completed.map {
                ($0.conversationJid, $0.conversationType)
            }
            completed.forEach {
                cancelReceiptTimeout(queuePrimary: $0.primary)
            }
            try realm.write {
                realm.delete(completed)
            }
            notifyPendingOutgoingCount()
            environment.log(
                "account_send_coordinator_delivery_receipt_completed",
                queueDiagnostics([
                    "originId": originId,
                    "stanzaId": stanzaId,
                    "completedCount": completed.count
                ])
            )
            chatKeys.forEach { conversationJid, conversationType in
                drainNextReadyMessage(conversationJid: conversationJid, conversationType: conversationType)
            }
        } catch {
            DDLogDebug("AccountSendCoordinator: deliveryReceiptReceived failed: \(error.localizedDescription)")
        }
    }

    func terminalFailure(originId: String, error: String) {
        do {
            let realm = try WRealm.safe()
            let failedItems = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter("owner == %@ AND originId == %@", environment.owner, originId)
            guard !failedItems.isEmpty else { return }
            let failed = Array(failedItems)
            let chatKeys = failed.map {
                QueueChatKey(jid: $0.conversationJid, type: $0.conversationType)
            }
            failed.forEach {
                cancelReceiptTimeout(queuePrimary: $0.primary)
            }
            try realm.write {
                failed.forEach { item in
                    item.state = .terminalFailed
                    item.lastError = error
                }
            }
            notifyPendingOutgoingCount()
            environment.log(
                "account_send_coordinator_terminal_failure",
                queueDiagnostics([
                    "originId": originId,
                    "error": error,
                    "failedCount": failed.count
                ])
            )
            chatKeys.forEach {
                drainNextReadyMessage(conversationJid: $0.jid, conversationType: $0.type)
            }
        } catch {
            DDLogDebug("AccountSendCoordinator: terminalFailure failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func localSendFailed(message: XMPPMessage, error: Error) -> Bool {
        guard let originId = message.elementID else {
            return false
        }
        do {
            let realm = try WRealm.safe()
            guard let item = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter(
                    "owner == %@ AND originId == %@ AND state_ == %@",
                    environment.owner,
                    originId,
                    OutgoingMessageQueueItem.State.awaitingReceipt.rawValue
                )
                .first else {
                return false
            }
            cancelReceiptTimeout(queuePrimary: item.primary)
            try realm.write {
                item.state = .queued
                item.lastError = error.localizedDescription
                item.lastAttemptAt = nil
            }
            notifyPendingOutgoingCount()
            environment.log(
                "account_send_coordinator_local_send_failed_requeued",
                queueDiagnostics([
                    "originId": originId,
                    "error": error.localizedDescription
                ])
            )
            return true
        } catch {
            DDLogDebug("AccountSendCoordinator: localSendFailed failed: \(error.localizedDescription)")
            return false
        }
    }

    func drainReadyQueue() {
        guard environment.isSendReady() else {
            environment.log(
                "account_send_coordinator_drain_skipped_not_ready",
                queueDiagnostics([:])
            )
            return
        }
        do {
            try pruneResolvedQueuedMessages()
            let realm = try WRealm.safe()
            let queued = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter(
                    "owner == %@ AND state_ == %@",
                    environment.owner,
                    OutgoingMessageQueueItem.State.queued.rawValue
                )
            let chatKeys = Set(queued.map { QueueChatKey(jid: $0.conversationJid, type: $0.conversationType) })
            environment.log(
                "account_send_coordinator_drain_started",
                queueDiagnostics(["chatCount": chatKeys.count])
            )
            chatKeys.forEach {
                drainNextReadyMessage(conversationJid: $0.jid, conversationType: $0.type)
            }
        } catch {
            DDLogDebug("AccountSendCoordinator: drainReadyQueue failed: \(error.localizedDescription)")
        }
    }

    private func drainNextReadyMessage(
        conversationJid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) {
        guard environment.isSendReady() else {
            environment.log(
                "account_send_coordinator_chat_drain_skipped_not_ready",
                queueDiagnostics([
                    "conversationJid": conversationJid,
                    "conversationType": conversationType.rawValue
                ])
            )
            return
        }
        guard let candidate = reserveNextCandidate(conversationJid: conversationJid, conversationType: conversationType) else {
            return
        }
        guard let message = makeMessage(from: candidate.stanzaXML) else {
            markCandidateTerminal(candidate, error: "invalid-stanza")
            drainNextReadyMessage(conversationJid: conversationJid, conversationType: conversationType)
            return
        }
        let messageToSend = canonicalizedDestinationMessage(
            message,
            conversationJid: conversationJid,
            conversationType: conversationType
        )
        let decorated = environment.decorateMessage(
            messageToSend,
            candidate.replayRequired,
            candidate.missRetryElement
        )
        scheduleReceiptTimeout(
            queuePrimary: candidate.queuePrimary,
            originId: candidate.originId,
            attemptCount: candidate.attemptCount
        )
        environment.log(
            "account_send_coordinator_message_sent_to_primary_stream",
            queueDiagnostics([
                "originId": candidate.originId,
                "queuePrimary": candidate.queuePrimary,
                "attemptCount": candidate.attemptCount,
                "replayRequired": candidate.replayRequired
            ])
        )
        environment.sendMessage(decorated)
    }

    private func reserveNextCandidate(
        conversationJid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> SendCandidate? {
        do {
            let realm = try WRealm.safe()
            let awaiting = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter(
                    "owner == %@ AND conversationJid == %@ AND conversationType_ == %@ AND state_ == %@",
                    environment.owner,
                    conversationJid,
                    conversationType.rawValue,
                    OutgoingMessageQueueItem.State.awaitingReceipt.rawValue
                )
            guard awaiting.isEmpty else {
                return nil
            }
            guard let item = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter(
                    "owner == %@ AND conversationJid == %@ AND conversationType_ == %@ AND state_ == %@",
                    environment.owner,
                    conversationJid,
                    conversationType.rawValue,
                    OutgoingMessageQueueItem.State.queued.rawValue
                )
                .sorted(by: [
                    SortDescriptor(keyPath: "createdOrder", ascending: true)
                ])
                .first else {
                return nil
            }
            let candidate = SendCandidate(
                queuePrimary: item.primary,
                originId: item.originId,
                stanzaXML: item.stanzaXML,
                replayRequired: item.replayRequired,
                missRetryElement: messageMissesRetryElementOnResend(item, realm: realm),
                attemptCount: item.attemptCount + 1
            )
            try realm.write {
                item.state = .awaitingReceipt
                item.attemptCount += 1
                item.lastAttemptAt = environment.now()
                item.lastError = nil
            }
            notifyPendingOutgoingCount()
            return candidate
        } catch {
            DDLogDebug("AccountSendCoordinator: reserveNextCandidate failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func makeMessage(from xml: String) -> XMPPMessage? {
        do {
            let document = try DDXMLDocument(xmlString: xml, options: 0)
            guard let root = document.rootElement() else {
                return nil
            }
            return XMPPMessage(from: root)
        } catch {
            DDLogDebug("AccountSendCoordinator: invalid queued stanza XML: \(error.localizedDescription)")
            return nil
        }
    }

    private func canonicalizedDestinationMessage(
        _ message: XMPPMessage,
        conversationJid: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> XMPPMessage {
        guard conversationType == .regular else {
            return message
        }
        guard let bareDestination = XMPPJID(string: conversationJid)?.bare ?? message.to?.bare else {
            return message
        }
        message.removeAttribute(forName: "to")
        message.addAttribute(withName: "to", stringValue: bareDestination)
        return message
    }

    private func markCandidateTerminal(_ candidate: SendCandidate, error: String) {
        do {
            let realm = try WRealm.safe()
            guard let item = realm.object(ofType: OutgoingMessageQueueItem.self, forPrimaryKey: candidate.queuePrimary) else {
                return
            }
            cancelReceiptTimeout(queuePrimary: item.primary)
            try realm.write {
                item.state = .terminalFailed
                item.lastError = error
            }
            notifyPendingOutgoingCount()
        } catch {
            DDLogDebug("AccountSendCoordinator: markCandidateTerminal failed: \(error.localizedDescription)")
        }
    }

    private func messageMissesRetryElementOnResend(_ item: OutgoingMessageQueueItem, realm: Realm) -> Bool {
        guard let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.messagePrimary) else {
            return false
        }
        return message.messageErrorCode == "405"
    }

    private func pruneResolvedQueuedMessages() throws {
        let realm = try WRealm.safe()
        let items = realm
            .objects(OutgoingMessageQueueItem.self)
            .filter("owner == %@ AND state_ != %@", environment.owner, OutgoingMessageQueueItem.State.terminalFailed.rawValue)
        guard !items.isEmpty else { return }
        let queuedItems = Array(items)
        try realm.write {
            queuedItems.forEach { item in
                guard let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.messagePrimary) else {
                    return
                }
                if message.archivedId.isNotEmpty || [.sended, .deliver, .read, .error].contains(message.state) {
                    cancelReceiptTimeout(queuePrimary: item.primary)
                    realm.delete(item)
                }
            }
        }
        notifyPendingOutgoingCount()
    }

    private func scheduleReceiptTimeout(queuePrimary: String, originId: String, attemptCount: Int) {
        cancelReceiptTimeout(queuePrimary: queuePrimary)
        let timeoutId = UUID().uuidString
        let cancellable = environment.scheduler.schedule(after: environment.receiptTimeout) { [weak self] in
            self?.handleReceiptTimeout(
                queuePrimary: queuePrimary,
                originId: originId,
                attemptCount: attemptCount,
                timeoutId: timeoutId
            )
        }
        receiptTimeoutLock.sync {
            receiptTimeouts[queuePrimary] = ReceiptTimeoutRegistration(
                id: timeoutId,
                attemptCount: attemptCount,
                cancellable: cancellable
            )
        }
    }

    private func cancelReceiptTimeout(queuePrimary: String) {
        var cancellable: AccountConnectionResilienceCancellable?
        receiptTimeoutLock.sync {
            cancellable = receiptTimeouts.removeValue(forKey: queuePrimary)?.cancellable
        }
        cancellable?.cancel()
    }

    private func cancelAllReceiptTimeouts() {
        var cancellables: [AccountConnectionResilienceCancellable] = []
        receiptTimeoutLock.sync {
            cancellables = receiptTimeouts.values.map(\.cancellable)
            receiptTimeouts.removeAll()
        }
        cancellables.forEach {
            $0.cancel()
        }
    }

    private func consumeReceiptTimeout(queuePrimary: String, attemptCount: Int, timeoutId: String) -> Bool {
        var consumed = false
        receiptTimeoutLock.sync {
            guard let registration = receiptTimeouts[queuePrimary],
                  registration.id == timeoutId,
                  registration.attemptCount == attemptCount else {
                return
            }
            _ = receiptTimeouts.removeValue(forKey: queuePrimary)
            consumed = true
        }
        return consumed
    }

    private func rescheduleAwaitingReceiptTimeouts() {
        guard environment.isSendReady() else {
            return
        }
        do {
            let realm = try WRealm.safe()
            let awaiting = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter(
                    "owner == %@ AND state_ == %@",
                    environment.owner,
                    OutgoingMessageQueueItem.State.awaitingReceipt.rawValue
                )
            Array(awaiting).forEach { item in
                scheduleReceiptTimeout(
                    queuePrimary: item.primary,
                    originId: item.originId,
                    attemptCount: item.attemptCount
                )
            }
        } catch {
            DDLogDebug("AccountSendCoordinator: rescheduleAwaitingReceiptTimeouts failed: \(error.localizedDescription)")
        }
    }

    private func handleReceiptTimeout(queuePrimary: String, originId: String, attemptCount: Int, timeoutId: String) {
        guard consumeReceiptTimeout(queuePrimary: queuePrimary, attemptCount: attemptCount, timeoutId: timeoutId) else {
            return
        }
        do {
            let realm = try WRealm.safe()
            guard let item = realm.object(ofType: OutgoingMessageQueueItem.self, forPrimaryKey: queuePrimary),
                  item.owner == environment.owner,
                  item.originId == originId,
                  item.state == .awaitingReceipt,
                  item.attemptCount == attemptCount else {
                return
            }
            let chatKey = QueueChatKey(jid: item.conversationJid, type: item.conversationType)
            if let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.messagePrimary),
               isResolvedForReceiptTimeout(message) {
                let diagnostics: [String: Any?] = [
                    "originId": originId,
                    "queuePrimary": item.primary,
                    "attemptCount": item.attemptCount,
                    "messageState": message.state.rawValue,
                    "hasArchivedId": message.archivedId.isNotEmpty
                ]
                try realm.write {
                    realm.delete(item)
                }
                notifyPendingOutgoingCount()
                environment.log(
                    "account_send_coordinator_receipt_timeout_resolved",
                    queueDiagnostics(diagnostics)
                )
                drainNextReadyMessage(conversationJid: chatKey.jid, conversationType: chatKey.type)
                return
            }
            if item.attemptCount <= 1 {
                try realm.write {
                    item.state = .queued
                    item.replayRequired = true
                    item.lastAttemptAt = nil
                    item.lastError = Self.deliveryReceiptTimeoutErrorCode
                }
                notifyPendingOutgoingCount()
                environment.log(
                    "account_send_coordinator_receipt_timeout_requeued",
                    queueDiagnostics([
                        "originId": originId,
                        "attemptCount": item.attemptCount
                    ])
                )
                drainNextReadyMessage(conversationJid: chatKey.jid, conversationType: chatKey.type)
            } else {
                try realm.write {
                    item.state = .terminalFailed
                    item.lastError = Self.deliveryReceiptTimeoutErrorCode
                    if let message = realm.object(ofType: MessageStorageItem.self, forPrimaryKey: item.messagePrimary),
                       message.archivedId.isEmpty {
                        message.state = .error
                        message.messageError = Self.deliveryReceiptTimeoutErrorMessage
                        message.messageErrorCode = Self.deliveryReceiptTimeoutErrorCode
                        message.references.forEach {
                            $0.hasError = true
                        }
                        realm.object(
                            ofType: LastChatsStorageItem.self,
                            forPrimaryKey: LastChatsStorageItem.genPrimary(
                                jid: message.opponent,
                                owner: message.owner,
                                conversationType: message.conversationType
                            )
                        )?.hasErrorInChat = true
                    }
                }
                notifyPendingOutgoingCount()
                environment.log(
                    "account_send_coordinator_receipt_timeout_terminal",
                    queueDiagnostics([
                        "originId": originId,
                        "attemptCount": item.attemptCount
                    ])
                )
                drainNextReadyMessage(conversationJid: chatKey.jid, conversationType: chatKey.type)
            }
        } catch {
            DDLogDebug("AccountSendCoordinator: handleReceiptTimeout failed: \(error.localizedDescription)")
        }
    }

    private func isResolvedForReceiptTimeout(_ message: MessageStorageItem) -> Bool {
        message.archivedId.isNotEmpty || [.sended, .deliver, .read].contains(message.state)
    }

    private func queueDiagnostics(_ details: [String: Any?]) -> [String: Any?] {
        var output = details
        if let snapshot = environment.sendReadinessSnapshot() {
            output["phase"] = "\(snapshot.phase)"
            output["reason"] = snapshot.reason
            output["canFlush"] = snapshot.canFlushApplicationStanzas
        } else {
            output["canFlush"] = environment.isSendReady()
        }

        do {
            let realm = try WRealm.safe()
            output["queuedCount"] = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter(
                    "owner == %@ AND state_ == %@",
                    environment.owner,
                    OutgoingMessageQueueItem.State.queued.rawValue
                )
                .count
            output["awaitingReceiptCount"] = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter(
                    "owner == %@ AND state_ == %@",
                    environment.owner,
                    OutgoingMessageQueueItem.State.awaitingReceipt.rawValue
                )
                .count
            output["pendingCount"] = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter(
                    "owner == %@ AND state_ != %@",
                    environment.owner,
                    OutgoingMessageQueueItem.State.terminalFailed.rawValue
                )
                .count
        } catch {
            output["queueDiagnosticError"] = error.localizedDescription
        }
        return output
    }

    private func notifyPendingOutgoingCount() {
        do {
            let realm = try WRealm.safe()
            let count = realm
                .objects(OutgoingMessageQueueItem.self)
                .filter(
                    "owner == %@ AND state_ != %@",
                    environment.owner,
                    OutgoingMessageQueueItem.State.terminalFailed.rawValue
                )
                .count
            environment.updatePendingOutgoingCount(count)
        } catch {
            DDLogDebug("AccountSendCoordinator: notifyPendingOutgoingCount failed: \(error.localizedDescription)")
        }
    }

    private struct QueueChatKey: Hashable {
        let jid: String
        let type: ClientSynchronizationManager.ConversationType
    }
}

private final class AccountConnectRetryContext: NSObject {
    let attemptID: UInt64?
    let trigger: AccountConnectTrigger

    init(attemptID: UInt64?, trigger: AccountConnectTrigger) {
        self.attemptID = attemptID
        self.trigger = trigger
    }
}

enum ConnectionDiagnosticsStreamKind: String {
    case primary
    case uiAction = "ui-action"
    case background
    case register
    case changePassword = "change-password"
    case accountDelete = "account-delete"
    case oneShot = "one-shot"
    case voip
}

struct ConnectionDiagnosticsTiming: Equatable {
    let elapsedMs: Int
    let deltaMs: Int?
}

struct ConnectionDiagnosticsExecutionContext: Equatable {
    let thread: String
    let queue: String

    static func current() -> ConnectionDiagnosticsExecutionContext {
        let threadName: String
        if Thread.isMainThread {
            threadName = "main"
        } else {
            threadName = String(format: "0x%x", pthread_mach_thread_np(pthread_self()))
        }

        let queueLabel = String(cString: __dispatch_queue_get_label(nil), encoding: .utf8) ?? "unknown"
        return ConnectionDiagnosticsExecutionContext(thread: threadName, queue: queueLabel)
    }
}

final class ConnectionDiagnosticsTimeline {
    static let shared = ConnectionDiagnosticsTimeline()

    private struct Key: Hashable {
        let stream: ConnectionDiagnosticsStreamKind
        let jid: String
        let attemptID: UInt64
    }

    private struct Entry {
        let startedAt: TimeInterval
        let lastAt: TimeInterval
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    func record(
        stream: ConnectionDiagnosticsStreamKind,
        jid: String?,
        attemptID: UInt64,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> ConnectionDiagnosticsTiming {
        let key = Key(stream: stream, jid: jid ?? "none", attemptID: attemptID)
        lock.lock()
        defer { lock.unlock() }

        if let entry = entries[key] {
            let elapsedMs = Self.milliseconds(from: max(0, now - entry.startedAt))
            let deltaMs = Self.milliseconds(from: max(0, now - entry.lastAt))
            entries[key] = Entry(startedAt: entry.startedAt, lastAt: now)
            return ConnectionDiagnosticsTiming(elapsedMs: elapsedMs, deltaMs: deltaMs)
        }

        entries[key] = Entry(startedAt: now, lastAt: now)
        return ConnectionDiagnosticsTiming(elapsedMs: 0, deltaMs: nil)
    }

    func resetAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private static func milliseconds(from seconds: TimeInterval) -> Int {
        return Int((seconds * 1000).rounded())
    }
}

struct ConnectionDiagnosticsLogger {
    static let prefix = "CONNECTION_DIAGNOSTICS"
    static let redactedValue = "[redacted]"

    #if DEBUG
    static let rawXMLLoggingEnabled = true
    #else
    static let rawXMLLoggingEnabled = false
    #endif

    static func log(
        event: String,
        stream: ConnectionDiagnosticsStreamKind,
        jid: String?,
        attemptID: UInt64? = nil,
        trigger: AccountConnectTrigger? = nil,
        phase: AccountStreamLifecyclePhase? = nil,
        state: String? = nil,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil,
        includeRawXML: Bool = rawXMLLoggingEnabled
    ) {
        let timing = attemptID.map {
            ConnectionDiagnosticsTimeline.shared.record(
                stream: stream,
                jid: jid,
                attemptID: $0
            )
        }
        DDLogInfo(
            line(
                event: event,
                stream: stream,
                jid: jid,
                attemptID: attemptID,
                trigger: trigger,
                phase: phase,
                state: state,
                details: details,
                rawXML: rawXML,
                error: error,
                includeRawXML: includeRawXML,
                timing: timing,
                executionContext: ConnectionDiagnosticsExecutionContext.current()
            )
        )
    }

    static func line(
        event: String,
        stream: ConnectionDiagnosticsStreamKind,
        jid: String?,
        attemptID: UInt64? = nil,
        trigger: AccountConnectTrigger? = nil,
        phase: AccountStreamLifecyclePhase? = nil,
        state: String? = nil,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil,
        includeRawXML: Bool = rawXMLLoggingEnabled,
        timing: ConnectionDiagnosticsTiming? = nil,
        executionContext: ConnectionDiagnosticsExecutionContext? = nil
    ) -> String {
        var parts: [String] = [
            prefix,
            "event=\(format(event))",
            "stream=\(stream.rawValue)",
            "jid=\(format(jid ?? "none"))"
        ]

        if let attemptID {
            parts.append("attempt=\(attemptID)")
        }
        if let trigger {
            parts.append("trigger=\(trigger.rawValue)")
        }
        if let phase {
            parts.append("phase=\(phase.rawValue)")
        }
        if let state {
            parts.append("state=\(format(state))")
        }
        if let timing {
            parts.append("elapsedMs=\(timing.elapsedMs)")
            if let deltaMs = timing.deltaMs {
                parts.append("deltaMs=\(deltaMs)")
            }
        }
        if let executionContext {
            parts.append("thread=\(format(executionContext.thread))")
            parts.append("queue=\(format(executionContext.queue))")
        }
        if let error {
            let nsError = error as NSError
            parts.append("errorDomain=\(format(nsError.domain))")
            parts.append("errorCode=\(nsError.code)")
            parts.append("errorDescription=\(format(nsError.localizedDescription))")
        }

        for key in details.keys.sorted() {
            guard let value = details[key], let unwrapped = value else { continue }
            parts.append("\(key)=\(format(unwrapped))")
        }

        if includeRawXML, let rawXML {
            parts.append("xml=\(format(redact(rawXML)))")
        }

        return parts.joined(separator: " ")
    }

    static func redact(_ rawXML: String) -> String {
        var output = rawXML

        let sensitiveElements = [
            "auth",
            "response",
            "device-secret",
            "device_secret",
            "deviceSecret",
            "xabberDeviceSecret",
            "validation-key",
            "validation_key",
            "validationKey",
            "encryption-key",
            "encryption_key",
            "encryptionKey",
            "access-token",
            "access_token",
            "accessToken",
            "refresh-token",
            "refresh_token",
            "refreshToken",
            "password",
            "token",
            "secret",
            "jwt"
        ]

        for element in sensitiveElements {
            output = replacing(
                pattern: "(?is)(<\(element)\\b[^>]*>)(.*?)(</\(element)>)",
                in: output,
                with: "$1\(redactedValue)$3"
            )
        }

        output = replacing(
            pattern: "(?i)\\b(device-secret|device_secret|deviceSecret|xabberDeviceSecret|validation-key|validation_key|validationKey|encryption-key|encryption_key|encryptionKey|access-token|access_token|accessToken|refresh-token|refresh_token|refreshToken|password|token|secret|jwt|authorization)\\s*=\\s*\"[^\"]*\"",
            in: output,
            with: "$1=\"\(redactedValue)\""
        )
        output = replacing(
            pattern: "(?i)\\b(device-secret|device_secret|deviceSecret|xabberDeviceSecret|validation-key|validation_key|validationKey|encryption-key|encryption_key|encryptionKey|access-token|access_token|accessToken|refresh-token|refresh_token|refreshToken|password|token|secret|jwt|authorization)\\s*=\\s*'[^']*'",
            in: output,
            with: "$1='\(redactedValue)'"
        )
        output = replacing(
            pattern: "(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]+",
            in: output,
            with: "Bearer \(redactedValue)"
        )

        return output
    }

    static func stateDescription(for stream: XMPPStream) -> String {
        [
            "disconnected=\(stream.isDisconnected)",
            "connected=\(stream.isConnected)",
            "connecting=\(stream.isConnecting)",
            "authenticating=\(stream.isAuthenticating)",
            "authenticated=\(stream.isAuthenticated)"
        ].joined(separator: ",")
    }

    private static func format(_ value: Any) -> String {
        let raw = String(describing: value)
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")

        if escaped.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) != nil
            || escaped.contains("=")
            || escaped.contains("<")
            || escaped.contains(">")
            || escaped.contains("\"") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private static func replacing(pattern: String, in value: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }
}

final class Account: NSObject {
//  main params
    var jid: String = ""
    override var description: String {
            return "Account \(jid)"
        }
//    var password: String
//    var token: String = ""
    var host: String
    var port: Int
    var username: String
//  settings
    var supportTokens: Bool = false
    var tokenUid: String = ""
    var savePassword: Bool = true
    var useSecureConnection: Bool = false
    var manuallySetHost: Bool = false
    var resource: String = ""
    var priority: Int = 0

//  XMPPFramework params
    var queue: DispatchQueue
    var xmppStream: XMPPStream
    lazy var xmppTaskScheduler: AccountXMPPTaskScheduler = AccountXMPPTaskScheduler(
        account: self,
        bootstrapGate: { [weak self] in
            self?.syncManager.isBootstrapCriticalSyncInProgress() ?? false
        }
    )
    let authenticationCounterTracker = XMPPAuthenticationCounterTracker()
    let connectionGate = AccountStreamLifecycleGate()
    let sendReadiness = AccountSendReadinessCoordinator()
    lazy var sendCoordinator: AccountSendCoordinator = AccountSendCoordinator(account: self)
    private lazy var connectionResilienceQueue = DispatchQueue(label: "com.xabber.account.connection-resilience.\(self.jid)")
    private lazy var connectionResilienceScheduler = DispatchAccountConnectionResilienceScheduler(queue: self.connectionResilienceQueue)
    private var lastEndpointResolutionSettingsKey: String?
    lazy var connectionResilience = AccountConnectionResilienceCoordinator(
        policy: .aggressive(),
        scheduler: self.connectionResilienceScheduler,
        actions: AccountConnectionResilienceActions(
            sendPing: { [weak self] in
                self?.sendResiliencePing() ?? false
            },
            forceClose: { [weak self] cause in
                self?.forceCloseForResilience(cause: cause)
            },
            requestReconnect: { [weak self] trigger, cause in
                self?.requestResilienceReconnect(trigger: trigger, cause: cause) ?? false
            },
            probeOnlineStream: { [weak self] in
                self?.logConnectionDiagnostics(event: "resilience_probe_online_stream")
            },
            canResumeStream: { [weak self] in
                self?.sm.canResumeStream() ?? false
            },
            skipFullSetupAfterResume: { [weak self] in
                self?.logConnectionDiagnostics(event: "stream_management_resume_skip_full_setup")
            },
            runFullSetupAfterAuthentication: { [weak self] in
                self?.logConnectionDiagnostics(event: "stream_management_resume_run_full_setup")
            },
            invalidateEndpointResolutionCache: { [weak self] reason in
                XMPPSRVResolver.invalidateCache(withReason: reason)
                self?.logConnectionDiagnostics(
                    event: "resolver_cache_invalidated",
                    details: ["reason": reason]
                )
            },
            markSuspectedStale: { [weak self] reason, snapshot in
                self?.handleConnectionSuspectedStale(reason: reason, snapshot: snapshot)
            },
            healthChanged: { [weak self] snapshot in
                self?.logConnectionDiagnostics(
                    event: "connection_health_snapshot",
                    details: [
                        "lastInboundAge": snapshot.lastInboundStanzaAt.map { ProcessInfo.processInfo.systemUptime - $0 },
                        "lastAckAge": snapshot.lastStreamManagementAckAt.map { ProcessInfo.processInfo.systemUptime - $0 },
                        "lastReceiptAge": snapshot.lastDeliveryReceiptAt.map { ProcessInfo.processInfo.systemUptime - $0 },
                        "lastPingAge": snapshot.lastSuccessfulPingAt.map { ProcessInfo.processInfo.systemUptime - $0 },
                        "lastOutboundAge": snapshot.lastOutboundStanzaAt.map { ProcessInfo.processInfo.systemUptime - $0 },
                        "pendingOutgoingCount": snapshot.pendingOutgoingCount,
                        "lastActivityAge": snapshot.lastActivityAge,
                        "isSuspectedStale": snapshot.isSuspectedStale,
                        "staleReason": snapshot.suspectedStaleReason?.rawValue
                    ]
                )
            },
            log: { [weak self] event, details in
                self?.logConnectionDiagnostics(event: event, details: details)
            }
        )
    )
    lazy var primaryStreamStanzaTracker = AccountPrimaryStreamStanzaTracker(
        configuration: .production,
        scheduler: self.connectionResilienceScheduler,
        onAckTimeout: { [weak self] stanza in
            self?.connectionResilience.notePrimaryStreamAckTimeout(
                stanzaId: stanza.stanzaId,
                generation: stanza.generation
            )
        }
    )
    private lazy var primaryStreamBootstrapSendGate = AccountPrimaryStreamBootstrapSendGate(
        now: { [weak self] in
            self?.connectionResilienceScheduler.now ?? ProcessInfo.processInfo.systemUptime
        }
    )
    private var networkPathMonitor: AccountNetworkPathMonitoring?
    private var isConnectionResilienceMonitoringStarted = false
    var pendingDisconnectCause: AccountDisconnectCause?
//  XMPPFramework modules
    var reconnect: XMPPReconnect
//  custom modules
    var devices: XMPPDeviceManager
    var xTokens: XTokenManager
    var disco: ServerDiscoManager
    var presences: PresenceManager
    var messages: MessageManager
    var roster: RosterManager
    var mam: MessageArchiveManager
    var carbons: CarbonsManager
    var lastChats: LastChats
    var csi: ClientStateIndicateManager
    var push: PushNotificationsManager
    var vcards: VCardManager
    var avatarManager: XmppAvatarManager
    var ping: PingManager
    var cloudStorage: XabberUploadManager
    var avatarUploader: AvatarUploadManager
    var blocked: BlockManager
    var chatStates: ChatStatesManager
    var chatMarkers: ChatMarkersManager
    var attention: AttentionManger
    var globalIndex: GlobalIndexManager
    var groupchats: GroupchatManager
    var deliveryManager: ReliableMessageDeliveryManager
    var msgDeleteManager: MessageDeleteManager
    var messageSchedule: XMPPMessageScheduleManager
    var syncManager: ClientSynchronizationManager
    var x509Manager: X509XMPPManager
    var omemo: OmemoManager
    var deliveryReceipts: MessageDeliveryReceipts
    var notifications: XMPPNotificationsManager
    var favorites: XMPPFavoritesManager
    var akeManager: AuthenticatedKeyExchangeManager
    var trustSharingManager: TrustSharingManager
    var abuse: XMPPAbuseManager
    
    var smStorage: XMPPStreamManagementMemoryStorage
    var sm: XMPPStreamManagement
    
    
    var carbonsEnabled: Bool = false
    var pushWasReceived: Bool {
        didSet {
            DDLogDebug("pushWasReceived was changed from \(oldValue)to \(self.pushWasReceived)")
        }
    }
    var pushLastMAMId: String
//  notification part
    var completionHandler: (() -> Void)?
    var completionHandlerTimer: Timer?
    var isInitialMAMRequestSend: Bool = false
//  Observable
    var statusState: BehaviorRelay<ResourceStatus> = BehaviorRelay(value: ResourceStatus.offline)
    var statusMessage: BehaviorRelay<String> = BehaviorRelay(value: "Offline")
    var pushStatusMessage: BehaviorRelay<Bool> = BehaviorRelay(value: false)
//  service data
    var delayedConnectTimer: Timer?
    var isPresenceUpdateRequestSend: Bool = false
    private var shouldSendBroadcastPresenceWhenReady: Bool = false
    private var pendingPresenceTargetJids: Set<String> = []
    var watchConnectionTimer: Timer?
    let connectionDiagnosticsLock = NSLock()
    var connectionDiagnosticsHeartbeatID: UInt64 = 0
    var startTLSStallWatchID: UInt64 = 0
    var startTLSDelegateCallbackWatchID: UInt64?
    
    var isRequestedAway: Bool = false
    var isBinded: Bool = false
    
    var isRegularPushRequestSended: Bool = false
    var isVoIPPushRequestSended: Bool = false
    
    var isSubscribedOnStateChange: Bool = false
    var isSynced: Bool = false
    var isConfigured: Bool = false
    
    var deviceName: String = ""
    
    public var isNewAccount: Bool = false

    static func username(from jid: String) -> String {
        String(jid.split(separator: "@").first ?? "")
    }
    
    init(jid: String, queue: DispatchQueue) {
        // set default connection fields
        self.jid = jid
        self.host = ""
        self.port = 5222
        // try to set default username
        self.username = Account.username(from: jid)
        // default push variables
        self.pushWasReceived = false
        self.pushLastMAMId = ""
        // set pointer to queue, in which application worked
        self.queue = queue
        // setting XMPPStream
        self.xmppStream = XMPPStream()
        self.presences = PresenceManager(withOwner: self.jid)
        self.messages = MessageManager(withOwner: self.jid, activeStream: true)
        self.roster = RosterManager(withOwner: self.jid)
        self.mam = MessageArchiveManager(withOwner: self.jid)
        self.carbons = CarbonsManager(withOwner: self.jid)
        self.lastChats = LastChats(withOwner: self.jid)
        self.blocked = BlockManager(withOwner: self.jid)
        self.vcards = VCardManager(withOwner: self.jid)
        self.avatarManager = XmppAvatarManager(withOwner: self.jid)
//        self.vCardAvatars = vCardAvatarManager(withOwner: self.j2id)
//        self.PEPAvatars = PEPAvatarManager(withOwner: self.jid)
        self.disco = ServerDiscoManager(withOwner: self.jid)
        self.cloudStorage = XabberUploadManager(withOwner: self.jid)
        self.avatarUploader = AvatarUploadManager(withOwner: self.jid)
        self.chatStates = ChatStatesManager(withOwner: self.jid)
        self.chatMarkers = ChatMarkersManager(withOwner: self.jid)
        self.attention = AttentionManger(withOwner: self.jid)
        self.ping = PingManager(withOwner: self.jid)
        self.csi = ClientStateIndicateManager(withOwner: self.jid)
        self.push = PushNotificationsManager(withOwner: self.jid)
        self.xTokens = XTokenManager(withOwner: self.jid)
        self.devices = XMPPDeviceManager(withOwner: self.jid)
        self.reconnect = XMPPReconnect(dispatchQueue: queue)
        self.globalIndex = GlobalIndexManager(withOwner: self.jid)
        self.groupchats = GroupchatManager(withOwner: self.jid)
        self.deliveryManager = ReliableMessageDeliveryManager(withOwner: self.jid)
        self.msgDeleteManager = MessageDeleteManager(withOwner: self.jid)
        self.messageSchedule = XMPPMessageScheduleManager(withOwner: self.jid)
        self.syncManager = ClientSynchronizationManager(withOwner: self.jid)
        self.omemo = OmemoManager(withOwner: self.jid)
        self.x509Manager = X509XMPPManager(withOwner: self.jid)
        self.smStorage = XMPPStreamManagementMemoryStorage()
        self.sm = XMPPStreamManagement(storage: self.smStorage, dispatchQueue: queue)
        self.deliveryReceipts = MessageDeliveryReceipts(withOwner: self.jid)
        self.notifications = XMPPNotificationsManager(withOwner: self.jid)
        self.favorites = XMPPFavoritesManager(withOwner: self.jid)
        self.akeManager = AuthenticatedKeyExchangeManager(withOwner: self.jid)
        self.trustSharingManager = TrustSharingManager(withOwner: self.jid)
        self.abuse = XMPPAbuseManager(withOwner: self.jid)
        // start init NSObject
        super.init()
        self.sendReadiness.onReadinessChanged = { [weak self] snapshot in
            guard let self else { return }
            self.logConnectionDiagnostics(
                event: "send_readiness_changed",
                details: [
                    "phase": "\(snapshot.phase)",
                    "canFlush": snapshot.canFlushApplicationStanzas,
                    "reason": snapshot.reason
                ]
            )
            if snapshot.canFlushApplicationStanzas {
                self.flushPendingPresenceSends()
                self.sendCoordinator.accountDidBecomeSendReady()
            }
        }
        self.messages.archiveQueryIdPersistenceResolver = { [weak self] queryId in
            self?.mam.shouldPersistArchiveQueryId(queryId) ?? false
        }
        AccountSendCoordinator.restoreRecoverableRegularMessages(owner: self.jid)
        self.registerModules()
        self.startConnectionResilienceMonitoring()
        self.lastChats.resetSyncedStatus()
        self.groupchats.reset()
        self.load()
//        xuploads.confi-gure()
//        self.asyncConnect()
    }

    @discardableResult
    func sendPrimaryStanza(
        _ stanza: XMPPElement,
        replayPolicy: PrimaryStreamReplayPolicy = .notReplayable
    ) -> PrimaryStreamSendResult {
        let stanzaId = PrimaryStreamStanzaIdentifier.ensureID(on: stanza)
        let effectiveReplayPolicy = primaryStreamReplayPolicy(for: stanza, requestedPolicy: replayPolicy)
        let isBootstrapActive = syncManager.isBootstrapCriticalSyncInProgress()
        if isBootstrapActive,
           AccountPrimaryStreamBootstrapSendGate.isLoginCriticalSelfDiscoInfo(stanza, ownerBareJID: jid) {
            logBootstrapSendGateAllowed(stanza: stanza, reason: "loginCriticalSelfDiscoInfo")
        }
        if case .queued(let queuedId) = primaryStreamBootstrapSendGate.prepareForSend(
            stanza,
            replayPolicy: effectiveReplayPolicy,
            isBootstrapActive: isBootstrapActive,
            ownerBareJID: jid
        ) {
            logBootstrapSendGateQueued(stanza: stanza, replayPolicy: effectiveReplayPolicy)
            return .queued(stanzaId: queuedId)
        }
        if shouldTrackPrimaryStreamStanza {
            let result = primaryStreamStanzaTracker.track(
                stanzaId: stanzaId,
                kind: primaryStreamStanzaKind(for: stanza),
                replayPolicy: effectiveReplayPolicy
            )
            if case .rejected(let violation) = result {
                logPrimaryStreamTrackingRejected(stanza: stanza, violation: violation)
                connectionResilience.notePrimaryStreamTrackingLimitRejected(violation)
                return .rejected(violation)
            }
        } else {
            logConnectionDiagnostics(
                event: "primary_stream_send_untracked_sm_not_ready",
                details: [
                    "id": stanzaId,
                    "kind": primaryStreamStanzaKind(for: stanza).rawValue,
                    "sendReady": sendReadiness.snapshot.canFlushApplicationStanzas
                ]
            )
        }

        xmppStream.send(stanza)
        return .sent(stanzaId: stanzaId)
    }

    func preparePrimaryStreamStanzaForSend(
        _ stanza: XMPPElement,
        replayPolicy: PrimaryStreamReplayPolicy = .notReplayable
    ) -> Bool {
        let effectiveReplayPolicy = primaryStreamReplayPolicy(for: stanza, requestedPolicy: replayPolicy)
        let isBootstrapActive = syncManager.isBootstrapCriticalSyncInProgress()
        if isBootstrapActive,
           AccountPrimaryStreamBootstrapSendGate.isLoginCriticalSelfDiscoInfo(stanza, ownerBareJID: jid) {
            logBootstrapSendGateAllowed(stanza: stanza, reason: "loginCriticalSelfDiscoInfo")
        }
        if case .queued = primaryStreamBootstrapSendGate.prepareForSend(
            stanza,
            replayPolicy: effectiveReplayPolicy,
            isBootstrapActive: isBootstrapActive,
            ownerBareJID: jid
        ) {
            logBootstrapSendGateQueued(stanza: stanza, replayPolicy: effectiveReplayPolicy)
            return false
        }
        guard shouldTrackPrimaryStreamStanza else { return true }

        let stanzaId = PrimaryStreamStanzaIdentifier.ensureID(on: stanza)
        let result = primaryStreamStanzaTracker.track(
            stanzaId: stanzaId,
            kind: primaryStreamStanzaKind(for: stanza),
            replayPolicy: effectiveReplayPolicy
        )
        if case .rejected(let violation) = result {
            logPrimaryStreamTrackingRejected(stanza: stanza, violation: violation)
            connectionResilience.notePrimaryStreamTrackingLimitRejected(violation)
            return false
        }
        return true
    }

    func notePrimaryStreamStanzaDidSend(_ stanza: XMPPElement) {
        guard let tracked = primaryStreamStanzaTracker.trackedStanza(stanzaId: stanza.elementID) else { return }
        if tracked.replayPolicy.requiresOutboundHealthConfirmation {
            connectionResilience.noteOutboundApplicationStanza(id: stanza.elementID)
        } else {
            let event: String
            switch tracked.replayPolicy {
            case .bootstrapClientSyncIQ:
                event = "primary_stream_bootstrap_sync_stanza_observed"
            case .longRunningBackgroundIQ:
                event = "primary_stream_long_running_background_stanza_observed"
            case .notReplayable, .durableRegularMessage, .latestPresence, .safeIdempotentIQ:
                event = "primary_stream_non_health_stanza_observed"
            }
            logConnectionDiagnostics(
                event: event,
                details: [
                    "id": stanza.elementID ?? "none",
                    "kind": tracked.kind.rawValue
                ]
            )
        }
        if sendReadiness.snapshot.canFlushApplicationStanzas {
            sm.requestAck()
        }
    }

    func notePrimaryStreamStanzaDidFailToSend(_ stanza: XMPPElement) {
        _ = primaryStreamStanzaTracker.noteSendFailed(id: stanza.elementID)
    }

    func snapshotTrackedPrimaryStanzas() -> [PrimaryStreamTrackedStanza] {
        primaryStreamStanzaTracker.snapshotTrackedPrimaryStanzas()
    }

    private var shouldTrackPrimaryStreamStanza: Bool {
        sendReadiness.snapshot.canFlushApplicationStanzas
    }

    private func primaryStreamReplayPolicy(
        for stanza: XMPPElement,
        requestedPolicy: PrimaryStreamReplayPolicy
    ) -> PrimaryStreamReplayPolicy {
        guard requestedPolicy == .notReplayable else {
            return requestedPolicy
        }
        if ClientSynchronizationManager.isClientSyncPaginationIQ(stanza) {
            return .bootstrapClientSyncIQ
        }
        if isLongRunningBackgroundIQ(stanza) {
            return .longRunningBackgroundIQ
        }
        return requestedPolicy
    }

    private func primaryStreamStanzaKind(for stanza: XMPPElement) -> PrimaryStreamStanzaKind {
        if stanza is XMPPIQ || stanza.name == "iq" {
            return .iq
        }
        if stanza is XMPPPresence || stanza.name == "presence" {
            return .presence
        }
        return .message
    }

    private func logPrimaryStreamTrackingRejected(
        stanza: XMPPElement,
        violation: PrimaryStreamTrackingLimitViolation
    ) {
        logConnectionDiagnostics(
            event: "primary_stream_stanza_tracking_rejected",
            details: [
                "id": stanza.elementID ?? "none",
                "kind": primaryStreamStanzaKind(for: stanza).rawValue,
                "violation": String(describing: violation)
            ],
            rawXML: stanza.xmlString
        )
    }

    private func isLongRunningBackgroundIQ(_ stanza: XMPPElement) -> Bool {
        guard stanza.name == "iq",
              ["get", "set"].contains(stanza.attributeStringValue(forName: "type")?.lowercased() ?? ""),
              let child = stanza.children?.compactMap({ $0 as? DDXMLElement }).first,
              child.name == "query",
              child.xmlns()?.hasPrefix("urn:xmpp:mam:") == true else {
            return false
        }
        return true
    }

    private func logBootstrapSendGateQueued(
        stanza: XMPPElement,
        replayPolicy: PrimaryStreamReplayPolicy
    ) {
        logConnectionDiagnostics(
            event: "primary_stream_bootstrap_send_gate_queued",
            details: [
                "id": stanza.elementID ?? "none",
                "kind": primaryStreamStanzaKind(for: stanza).rawValue,
                "type": stanza.attributeStringValue(forName: "type") ?? "none",
                "childNamespace": stanza.children?.compactMap({ $0 as? DDXMLElement }).first?.xmlns() ?? "none",
                "replayPolicy": String(describing: replayPolicy),
                "queuedCount": primaryStreamBootstrapSendGate.queuedCount
            ],
            rawXML: stanza.xmlString
        )
    }

    private func logBootstrapSendGateAllowed(stanza: XMPPElement, reason: String) {
        logConnectionDiagnostics(
            event: "primary_stream_bootstrap_send_gate_allowed",
            details: [
                "id": stanza.elementID ?? "none",
                "kind": primaryStreamStanzaKind(for: stanza).rawValue,
                "type": stanza.attributeStringValue(forName: "type") ?? "none",
                "childNamespace": stanza.children?.compactMap({ $0 as? DDXMLElement }).first?.xmlns() ?? "none",
                "reason": reason
            ],
            rawXML: stanza.xmlString
        )
    }

    func flushBootstrapQueuedPrimaryStanzas(reason: String) {
        guard !syncManager.isBootstrapCriticalSyncInProgress() else {
            logConnectionDiagnostics(
                event: "primary_stream_bootstrap_send_gate_flush_deferred",
                details: [
                    "reason": reason,
                    "queuedCount": primaryStreamBootstrapSendGate.queuedCount
                ]
            )
            return
        }

        let queuedStanzas = primaryStreamBootstrapSendGate.drainQueuedStanzas()
        guard queuedStanzas.isNotEmpty else { return }

        logConnectionDiagnostics(
            event: "primary_stream_bootstrap_send_gate_flush_start",
            details: [
                "reason": reason,
                "count": queuedStanzas.count,
                "iq": queuedStanzas.filter { $0.kind == .iq }.count,
                "presence": queuedStanzas.filter { $0.kind == .presence }.count,
                "message": queuedStanzas.filter { $0.kind == .message }.count
            ]
        )

        queuedStanzas.forEach { queued in
            guard let stanza = queued.makeElement() else {
                logConnectionDiagnostics(
                    event: "primary_stream_bootstrap_send_gate_flush_drop_invalid_xml",
                    details: [
                        "id": queued.stanzaId,
                        "kind": queued.kind.rawValue,
                        "age": queued.queuedAge
                    ]
                )
                return
            }

            logConnectionDiagnostics(
                event: "primary_stream_bootstrap_send_gate_flush_send",
                details: [
                    "id": queued.stanzaId,
                    "kind": queued.kind.rawValue,
                    "type": queued.stanzaType ?? "none",
                    "childNamespace": queued.childNamespace ?? "none",
                    "age": queued.queuedAge
                ],
                rawXML: queued.xmlString
            )
            _ = sendPrimaryStanza(stanza, replayPolicy: queued.replayPolicy)
        }

        logConnectionDiagnostics(
            event: "primary_stream_bootstrap_send_gate_flush_finish",
            details: [
                "reason": reason,
                "count": queuedStanzas.count
            ]
        )
    }

    func discardBootstrapQueuedPrimaryStanzas(reason: String) {
        let count = primaryStreamBootstrapSendGate.queuedCount
        primaryStreamBootstrapSendGate.removeAll()
        guard count > 0 else { return }
        logConnectionDiagnostics(
            event: "primary_stream_bootstrap_send_gate_discard",
            details: [
                "reason": reason,
                "count": count
            ]
        )
    }
    
    private func startConnectionResilienceMonitoring() {
        guard !isConnectionResilienceMonitoringStarted else { return }
        isConnectionResilienceMonitoringStarted = true
        connectionResilience.setForegroundActive(UIApplication.shared.applicationState != .background)
        let monitor = AccountNWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] snapshot in
            self?.connectionResilience.networkPathDidChange(snapshot)
        }
        monitor.start(queue: self.connectionResilienceQueue)
        networkPathMonitor = monitor
    }

    private func configureStreamManagementForCurrentStream() {
        self.sm.removeDelegate(self)
        if self.sm.xmppStream !== self.xmppStream {
            self.sm.deactivate()
            self.sm.activate(self.xmppStream)
        }
        self.sm.autoResume = true
        self.sm.addDelegate(self, delegateQueue: self.queue)
        self.sm.automaticallyRequestAcks(afterStanzaCount: 1, orTimeout: 4)
        self.logConnectionDiagnostics(
            event: "stream_management_prepared",
            details: [
                "autoResume": self.sm.autoResume,
                "canResume": self.sm.canResumeStream()
            ]
        )
    }

    func configureStream() {
        let privacyLevelRaw = SettingManager.shared.getString(for: "privacy_level") ?? CommonConfigManager.shared.config.default_privacy_level
        let privacyLevel = SettingManager.PrivacyLevel(rawValue: privacyLevelRaw) ?? .incognito
        self.xmppStream.shouldRequestXToken = false
        self.xmppStream.shouldRegisterDevice = false
        self.xmppStream.xabberClientInfo = CommonConfigManager.shared.config.app_name
        if privacyLevel == .serverContacts{
            self.xmppStream.xabberPublicLabel = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        } else {
            self.xmppStream.xabberPublicLabel = self.deviceName
        }
        if privacyLevel == .incognito {
            self.xmppStream.xabberDeviceInfo = self.deviceName
        } else {
            self.xmppStream.xabberDeviceInfo = [[UIDevice.modelName, ","].joined(),  "iOS", UIDevice.current.systemVersion].joined(separator: " ")
        }
        self.xmppStream.myJID = XMPPJID(string: jid, resource: AccountManager.defaultResource)
        self.xmppStream.startTLSPolicy = XMPPStreamStartTLSPolicy.preferred
        self.xmppStream.keepAliveInterval = 60
        self.xmppStream.removeDelegate(self, delegateQueue: self.queue)
        self.xmppStream.removeDelegate(self)
        self.xmppStream.addDelegate(self, delegateQueue: self.queue)
        self.configureStreamManagementForCurrentStream()
        DDLogDebug("configured primary stream jid=\(self.jid) resource=\(self.xmppStream.myJID?.resource ?? "none") delegateAssigned=true streamState=\(self.streamStateDescription)")
        self.logConnectionDiagnostics(
            event: "stream_configured",
            details: [
                "resource": self.xmppStream.myJID?.resource ?? "none",
                "tlsPolicy": self.xmppStream.startTLSPolicy.rawValue,
                "keepAlive": self.xmppStream.keepAliveInterval
            ]
        )
    }
    
    func resetStream() {
        self.logConnectionDiagnostics(event: "reset_stream_requested")
        self.xmppTaskScheduler.reset()
        self.cancelDelayedConnectTimer()
        self.connectionGate.reset()
        self.sendReadiness.markDisconnected(cause: self.pendingDisconnectCause ?? .accidentalSocket)
        self.sendCoordinator.streamDidDisconnect(canResume: self.sm.canResumeStream())
        self.primaryStreamStanzaTracker.noteStreamDidDisconnect(canResume: self.sm.canResumeStream())
        self.statusState.accept(.offline)
        self.statusMessage.accept(RosterUtils.shared.convertStatus(.offline))
        self.xmppStream.abortConnecting()
        self.xmppStream.disconnect()
        self.xmppStream.asyncSocket.disconnect()
        self.xmppStream.removeDelegate(self)
        self.xmppStream = XMPPStream()
        self.logConnectionDiagnostics(event: "reset_stream_completed")
    }
    
    func registerModules() {
        self.disco.register(mam)
        self.disco.register(csi)
        self.disco.register(push)
        self.disco.register(carbons)
        self.disco.register(chatMarkers)
        self.disco.register(presences)
        self.disco.register(avatarManager)
        self.disco.register(devices)
        self.disco.register(omemo)
        self.disco.register(x509Manager)
        self.disco.register(trustSharingManager)
        self.disco.register(messageSchedule)
    }
    
    public final func registerRegularPushForAccount() {
        if !self.isRegularPushRequestSended {
            self.isRegularPushRequestSended = true
            DispatchQueue.global(qos: .background).async {
                let didStart = APNSManager.shared.sendRegistrationRequest(forJid: self.jid, voip: false) { success in
                    self.isRegularPushRequestSended = success
                }
                if !didStart {
                    self.isRegularPushRequestSended = false
                }
            }
        }
    }
    
    public final func registerVoIPPushForAccount() {
        if !self.isVoIPPushRequestSended {
            self.isVoIPPushRequestSended = true
            DispatchQueue.global(qos: .background).async {
                let didStart = APNSManager.shared.sendRegistrationRequest(forJid: self.jid, voip: true) { success in
                    self.isVoIPPushRequestSended = success
                }
                if !didStart {
                    self.isVoIPPushRequestSended = false
                }
            }
        }
    }
    
/**
*    calls after roster populating
*    sets normal state for reconnect, synced vcards and message history
*    sends register for push notification request
**/
    func configureBase() {
//        DefaultAvatarManager.shared.updateAvatars(for: self.jid)
        self.configureStreamManagementForCurrentStream()
        if !self.sm.didResume {
            self.sendReadiness.markStreamManagementEnableRequested()
            self.sm.enable(withResumption: true, maxTimeout: 3600)
            self.logConnectionDiagnostics(
                event: "stream_management_configured",
                details: [
                    "autoResume": self.sm.autoResume,
                    "resumptionTimeout": 3600
                ]
            )
        } else {
            self.sendReadiness.markStreamManagementResumeSucceeded()
            self.logConnectionDiagnostics(event: "stream_management_enable_skipped_resumed")
        }
        if isConfigured {
            return
        }
        isConfigured = true
        self.reconnect.activate(self.xmppStream)
        self.reconnect.addDelegate(self, delegateQueue: self.queue)
        self.reconnect.autoReconnect = false
        self.reconnect.reconnectDelay = 1
        self.reconnect.reconnectTimerInterval = 2
        self.logConnectionDiagnostics(
            event: "reconnect_configured",
            details: [
                "autoReconnect": self.reconnect.autoReconnect,
                "delay": self.reconnect.reconnectDelay,
                "timerInterval": self.reconnect.reconnectTimerInterval
            ]
        )

        
    }
    
/**
 *    calls after base configuration
 *    enables XMPP features: message carbons, push notifications
 **/
    func configureExtensions() {
        self.carbons.set(xmppStream, to: .enabled)
        self.push.enable(xmppStream: self.xmppStream) {
            result in
            self.pushStatusMessage.accept(result)
        }
        
//        ApplicationStateManager.shared.checkApplicationBlockedState(for: self.jid)
    }
    
    func updateExtensions() {
        if self.xmppStream.isDisconnected {
            
        }
        let extensions: [AbstractXMPPManager] = [
            self.devices,
            self.xTokens,
            self.disco,
            self.presences,
            self.messages,
            self.roster,
            self.mam,
            self.carbons,
            self.lastChats,
            self.csi,
            self.push,
            self.vcards,
            self.avatarManager,
            self.ping,
            self.avatarUploader,
            self.blocked,
            self.chatStates,
            self.chatMarkers,
            self.attention,
            self.globalIndex,
            self.groupchats,
            self.deliveryManager,
            self.msgDeleteManager,
            self.messageSchedule,
            self.syncManager,
            self.x509Manager,
            self.omemo,
            self.deliveryReceipts,
            self.akeManager,
            self.trustSharingManager,
        ]
        extensions.forEach {
            [unowned self] module in
            module.onStreamPrepared(self.xmppStream)
        }
    }
    
/**
 *    open CocoaAsyncSocket and create XMPP session for JID with resource
 *    properties @manuallySetResource and @manuallySetHost sets in connection settings screen
 *    XMPPStream creates in specialized queue, not in main thread
 *    all DB  write operations must perform in thread, which contains XMPPStream
 *    to put XMPPStream into special thread, this method must been calls from DispatchQueue.global(qos: ).async {}
 **/
    @discardableResult
    final func requestConnect(
        trigger: AccountConnectTrigger,
        forceReset: Bool = false,
        prepareStream: (() -> Void)? = nil
    ) -> Bool {
        let frameworkActivePhase = forceReset ? nil : self.frameworkActivePhase()
        let decision = AccountStreamConnectPreflight.decide(
            gate: self.connectionGate,
            trigger: trigger,
            forceReset: forceReset,
            frameworkActivePhase: frameworkActivePhase,
            streamIsDisconnected: self.xmppStream.isDisconnected
        )

        switch decision {
        case .start(let attemptID, let stalePhase):
            if let stalePhase {
                DDLogDebug("reset stale account connection gate jid=\(self.jid) trigger=\(trigger.rawValue) stalePhase=\(stalePhase.rawValue) streamState=\(self.streamStateDescription)")
                self.logConnectionDiagnostics(
                    event: "connect_gate_reset_stale",
                    trigger: trigger,
                    details: ["stalePhase": stalePhase.rawValue]
                )
            }
            self.logConnectionDiagnostics(
                event: "connect_request_started",
                attemptID: attemptID,
                trigger: trigger,
                details: ["forceReset": forceReset]
            )
            self.sendReadiness.markConnecting(trigger: trigger)
            prepareStream?()
            self.performConnect(attemptID: attemptID, trigger: trigger)
            return true

        case .skip(let phase, let activeAttemptID, let reason):
            DDLogDebug("skip duplicate account connect jid=\(self.jid) trigger=\(trigger.rawValue) phase=\(phase.rawValue) attempt=\(activeAttemptID.map(String.init) ?? "none") streamState=\(self.streamStateDescription)")
            let details: [String: Any?] = [
                "activeAttempt": activeAttemptID.map(String.init) ?? "none",
                "forceReset": forceReset,
                "reason": reason.rawValue,
                "configurationSkipped": true,
                "activePhase": frameworkActivePhase?.rawValue
            ]
            if reason == .frameworkActive {
                self.logConnectionDiagnostics(
                    event: "connect_request_skipped_framework_active",
                    trigger: trigger,
                    phase: phase,
                    details: details
                )
            } else {
                self.logConnectionDiagnostics(
                    event: "connect_request_skipped_gate",
                    trigger: trigger,
                    phase: phase,
                    details: details
                )
            }
            self.logConnectionDiagnostics(
                event: "connect_request_skipped_before_configuration",
                trigger: trigger,
                phase: phase,
                details: details
            )
            return false
        }
    }

    @discardableResult
    final func requestForegroundConnectionRecovery(trigger: AccountConnectTrigger = .uiActionOpen) -> Bool {
        let readiness = self.sendReadiness.snapshot
        let gateSnapshot = self.connectionGate.snapshot()
        let healthSnapshot = self.connectionResilience.healthSnapshot
        let decision = AccountForegroundConnectionRecoveryPolicy.decide(
            canFlushApplicationStanzas: readiness.canFlushApplicationStanzas,
            lifecyclePhase: gateSnapshot.phase,
            isNetworkPathSatisfied: healthSnapshot.isNetworkPathSatisfied
        )
        self.logConnectionDiagnostics(
            event: "foreground_connection_recovery_evaluated",
            trigger: trigger,
            phase: gateSnapshot.phase,
            details: [
                "decision": String(describing: decision),
                "sendReady": readiness.canFlushApplicationStanzas,
                "readinessPhase": "\(readiness.phase)",
                "pathSatisfied": healthSnapshot.isNetworkPathSatisfied
            ]
        )

        guard decision == .requestImmediateReconnect else {
            return false
        }

        self.connectionResilience.requestImmediateReconnect(
            cause: .accidentalSocket,
            trigger: trigger
        )
        return true
    }

    private func configureEndpointResolutionForConnect() {
        let endpointSettingsKey = "\(self.manuallySetHost)|\(self.host)|\(self.port)"
        if endpointSettingsKey != self.lastEndpointResolutionSettingsKey {
            XMPPSRVResolver.invalidateCache(withReason: "account-endpoint-settings-changed")
            self.lastEndpointResolutionSettingsKey = endpointSettingsKey
            self.logConnectionDiagnostics(
                event: "resolver_cache_invalidated",
                details: ["reason": "account-endpoint-settings-changed"]
            )
        }

        self.xmppStream.certificatePeerName = self.xmppStream.myJID?.domain
        if self.manuallySetHost {
            self.xmppStream.hostName = self.host
            self.xmppStream.hostPort = UInt16(self.port)
        } else {
            self.xmppStream.hostName = nil
            self.xmppStream.hostPort = 5222
        }
    }

    @objc
    final func connect() {
        self.requestConnect(trigger: .legacyDirect)
    }

    final func cancelDelayedConnectTimer() {
        if self.delayedConnectTimer != nil {
            self.delayedConnectTimer?.invalidate()
            self.delayedConnectTimer = nil
        }
    }

    final func handleConnectTimeout() {
        let attemptID = self.connectionGate.snapshot().activeAttemptID
        guard self.connectionGate.canRetryTimeout(for: attemptID) else {
            DDLogDebug("skip account timeout retry jid=\(self.jid) phase=\(self.connectionGate.snapshot().phase.rawValue) attempt=\(attemptID.map(String.init) ?? "none") streamState=\(self.streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "connect_timeout_retry_skipped",
                details: ["timeoutAttempt": attemptID.map(String.init) ?? "none"]
            )
            AccountManager.shared.markAsNotConnecting(
                jid: self.jid,
                reason: "connect_timeout_retry_skipped",
                clearAuthentication: true
            )
            return
        }

        self.logConnectionDiagnostics(
            event: "connect_timeout_retry_scheduled",
            details: ["timeoutAttempt": attemptID.map(String.init) ?? "none"]
        )
        self.scheduleConnectRetry(after: 1, trigger: .timeoutRetry, attemptID: attemptID)
    }

    private func performConnect(attemptID: UInt64, trigger: AccountConnectTrigger) {
        self.cancelDelayedConnectTimer()
        if self.xmppStream.isConnecting
            || self.xmppStream.isConnected
            || self.xmppStream.isAuthenticated
            || self.xmppStream.isAuthenticating {
            self.connectionGate.adoptFrameworkActivePhase(self.frameworkActivePhase() ?? .connecting)
            DDLogDebug("skip duplicate account connect jid=\(self.jid) trigger=\(trigger.rawValue) phase=\(self.connectionGate.snapshot().phase.rawValue) attempt=\(attemptID) streamState=\(self.streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "connect_perform_skipped_stream_active",
                attemptID: attemptID,
                trigger: trigger
            )
            return
        }
        if self.resource.isNotEmpty {
            self.xmppStream.myJID = XMPPJID(string: self.jid, resource: self.resource)
        } else {
            self.xmppStream.myJID = XMPPJID(string: self.jid, resource: AccountManager.defaultResource)
        }
        self.configureEndpointResolutionForConnect()
        if self.push.node != "" && self.push.service != "" {
            self.pushStatusMessage.accept(true)
//            Account§Manager.shared.markAsConnecting(jid: self.jid)
        }
        do {
            DDLogDebug("primary stream connect jid=\(self.jid) trigger=\(trigger.rawValue) attempt=\(attemptID) resource=\(self.xmppStream.myJID?.resource ?? "none") manualHost=\(self.manuallySetHost) hostPresent=\(self.xmppStream.hostName?.isEmpty == false) port=\(self.xmppStream.hostPort) streamState=\(self.streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "connect_start",
                attemptID: attemptID,
                trigger: trigger,
                details: [
                    "resource": self.xmppStream.myJID?.resource ?? "none",
                    "manualHost": self.manuallySetHost,
                    "hostPresent": self.xmppStream.hostName?.isEmpty == false,
                    "host": self.xmppStream.hostName ?? "jid-domain",
                    "port": self.xmppStream.hostPort,
                    "timeout": 15
                ]
            )
            self.beginConnectionDiagnosticsHeartbeat()
            AccountManager.shared.markAsConnecting(jid: self.jid)
            try self.xmppStream.connect(withTimeout: 15)
        } catch {
            DDLogDebug("cant connect: \(error.localizedDescription)")
            self.logConnectionDiagnostics(
                event: "connect_throw",
                attemptID: attemptID,
                trigger: trigger,
                error: error
            )
            self.connectionGate.markFailed()
            self.sendReadiness.markStreamError(error.localizedDescription)
            self.statusMessage.accept("Offline")
            AccountManager.shared.changeNewUserState(for: self.jid, to: .failure("Server not found"))
            AccountManager.shared.markAsNotConnecting(
                jid: self.jid,
                reason: "connect_throw",
                clearAuthentication: true
            )
//            this.$store.state.current_org_id
        }
        self.isBinded = false
    }

    private func sendResiliencePing() -> Bool {
        self.queue.async { [weak self] in
            guard let self else { return }
            guard !self.syncManager.isBootstrapCriticalSyncInProgress() else {
                self.logConnectionDiagnostics(
                    event: "resilience_ping_suppressed_bootstrap_sync",
                    trigger: .livenessProbe,
                    details: ["reason": "bootstrapSync"]
                )
                self.connectionResilience.notePingResult(success: true)
                return
            }
            guard self.xmppStream.isAuthenticated else {
                self.logConnectionDiagnostics(event: "resilience_ping_send_skipped", trigger: .livenessProbe, details: ["reason": "notAuthenticated"])
                self.connectionResilience.notePingResult(success: false)
                return
            }

            self.ping.send(
                onSuccess: { iq in
                    self.logConnectionDiagnostics(
                        event: "resilience_ping_iq_sent",
                        trigger: .livenessProbe,
                        details: ["id": iq.elementID ?? "none"]
                    )
                    self.sendPrimaryStanza(iq, replayPolicy: .notReplayable)
                },
                onFailure: {
                    self.logConnectionDiagnostics(event: "resilience_ping_queue_limit", trigger: .livenessProbe)
                    self.connectionResilience.notePingResult(success: false)
                }
            )
        }
        return true
    }

    private func handleConnectionSuspectedStale(
        reason: AccountConnectionStaleReason,
        snapshot: AccountConnectionHealthSnapshot
    ) {
        self.sendReadiness.markSuspectedStale(reason: reason.rawValue)
        self.statusState.accept(.offline)
        self.statusMessage.accept("Reconnecting")
        self.logConnectionDiagnostics(
            event: "connection_health_marked_stale",
            trigger: .livenessProbe,
            details: [
                "reason": reason.rawValue,
                "lastActivityAge": snapshot.lastActivityAge,
                "pendingOutgoingCount": snapshot.pendingOutgoingCount
            ]
        )
    }

    private func forceCloseForResilience(cause: AccountDisconnectCause) {
        self.sendReadiness.markDisconnected(cause: cause)
        self.statusState.accept(.offline)
        self.statusMessage.accept("Offline")
        self.queue.async { [weak self] in
            guard let self else { return }
            self.pendingDisconnectCause = cause
            self.reconnect.autoReconnect = false
            self.logConnectionDiagnostics(
                event: "resilience_force_close",
                trigger: .livenessProbe,
                details: ["cause": cause.rawValue]
            )
            self.xmppStream.abortConnecting()
            self.xmppStream.disconnect()
            self.xmppStream.asyncSocket.disconnect()
            self.connectionGate.markDisconnected()
            self.sendReadiness.markDisconnected(cause: cause)
            self.sendCoordinator.streamDidDisconnect(canResume: self.sm.canResumeStream())
            self.primaryStreamStanzaTracker.noteStreamDidDisconnect(canResume: self.sm.canResumeStream())
            AccountManager.shared.markAsConnecting(jid: self.jid)
        }
    }

    private func requestResilienceReconnect(
        trigger: AccountConnectTrigger,
        cause: AccountDisconnectCause
    ) -> Bool {
        self.logConnectionDiagnostics(
            event: "resilience_reconnect_requested",
            trigger: trigger,
            details: [
                "cause": cause.rawValue,
                "canResume": self.sm.canResumeStream()
            ]
        )
        self.queue.async { [weak self] in
            guard let self else { return }
            self.resetStream()
            _ = self.requestConnect(
                trigger: trigger,
                forceReset: true,
                prepareStream: { self.configureStream() }
            )
        }
        return true
    }

    final func scheduleConnectRetry(after delay: TimeInterval, trigger: AccountConnectTrigger, attemptID: UInt64?) {
        guard self.delayedConnectTimer == nil else { return }
        self.logConnectionDiagnostics(
            event: "connect_retry_timer_scheduled",
            trigger: trigger,
            details: [
                "delay": delay,
                "retryAttempt": attemptID.map(String.init) ?? "none"
            ]
        )
        let context = AccountConnectRetryContext(attemptID: attemptID, trigger: trigger)
        self.delayedConnectTimer = Timer(
            timeInterval: delay,
            target: self,
            selector: #selector(self.delayedConnectTimerDidFire(_:)),
            userInfo: context,
            repeats: false
        )
        RunLoop.main.add(self.delayedConnectTimer!, forMode: RunLoop.Mode.default)
    }

    @objc
    private func delayedConnectTimerDidFire(_ timer: Timer) {
        let context = timer.userInfo as? AccountConnectRetryContext
        self.delayedConnectTimer = nil

        if let attemptID = context?.attemptID,
           !self.connectionGate.canRetryTimeout(for: attemptID) {
            DDLogDebug("skip stale account retry jid=\(self.jid) trigger=\(context?.trigger.rawValue ?? "unknown") attempt=\(attemptID) phase=\(self.connectionGate.snapshot().phase.rawValue) streamState=\(self.streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "connect_retry_timer_skipped_stale",
                trigger: context?.trigger ?? .timeoutRetry,
                details: ["retryAttempt": attemptID]
            )
            return
        }

        self.logConnectionDiagnostics(
            event: "connect_retry_timer_fired",
            trigger: context?.trigger ?? .timeoutRetry,
            details: ["retryAttempt": context?.attemptID.map(String.init) ?? "none"]
        )
        self.resetStream()
        self.requestConnect(
            trigger: context?.trigger ?? .timeoutRetry,
            forceReset: true,
            prepareStream: { self.configureStream() }
        )
    }

    private func frameworkActivePhase() -> AccountStreamLifecyclePhase? {
        if self.xmppStream.isAuthenticated {
            return .online
        }
        if self.xmppStream.isAuthenticating {
            return .authenticating
        }
        if self.xmppStream.isConnected {
            return .postAuthSetup
        }
        if self.xmppStream.isConnecting {
            return .connecting
        }
        return nil
    }

    private var streamStateDescription: String {
        return ConnectionDiagnosticsLogger.stateDescription(for: self.xmppStream)
    }

    final func logConnectionDiagnostics(
        event: String,
        attemptID: UInt64? = nil,
        trigger: AccountConnectTrigger? = nil,
        phase: AccountStreamLifecyclePhase? = nil,
        details: [String: Any?] = [:],
        rawXML: String? = nil,
        error: Error? = nil
    ) {
        let snapshot = self.connectionGate.snapshot()
        ConnectionDiagnosticsLogger.log(
            event: event,
            stream: .primary,
            jid: self.jid,
            attemptID: attemptID ?? snapshot.activeAttemptID,
            trigger: trigger,
            phase: phase ?? snapshot.phase,
            state: self.streamStateDescription,
            details: details,
            rawXML: rawXML,
            error: error
        )
    }

    final func beginConnectionDiagnosticsHeartbeat() {
        connectionDiagnosticsLock.lock()
        connectionDiagnosticsHeartbeatID += 1
        let heartbeatID = connectionDiagnosticsHeartbeatID
        connectionDiagnosticsLock.unlock()
        self.scheduleConnectionDiagnosticsHeartbeat(id: heartbeatID)
    }

    final func beginStartTLSDiagnosticsWatch() {
        let snapshot = self.connectionGate.snapshot()
        connectionDiagnosticsLock.lock()
        startTLSStallWatchID += 1
        let watchID = startTLSStallWatchID
        startTLSDelegateCallbackWatchID = nil
        connectionDiagnosticsLock.unlock()

        let attemptID = snapshot.activeAttemptID
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            guard self.shouldLogStartTLSStall(watchID: watchID, attemptID: attemptID) else { return }
            let snapshot = self.connectionGate.snapshot()
            ConnectionDiagnosticsLogger.log(
                event: "tls_stall_detected",
                stream: .primary,
                jid: self.jid,
                attemptID: attemptID,
                phase: snapshot.phase,
                details: [
                    "reason": "tlsDelegateCallbackNotObservedWithin2s",
                    "watchID": watchID
                ]
            )
        }
    }

    final func markStartTLSDelegateCallbackEntered() {
        connectionDiagnosticsLock.lock()
        startTLSDelegateCallbackWatchID = startTLSStallWatchID
        connectionDiagnosticsLock.unlock()
    }

    private func scheduleConnectionDiagnosticsHeartbeat(id: UInt64) {
        let expectedAt = ProcessInfo.processInfo.systemUptime + 1
        self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentConnectionDiagnosticsHeartbeat(id: id) else { return }

            let now = ProcessInfo.processInfo.systemUptime
            let delayMs = Int((max(0, now - expectedAt) * 1000).rounded())
            if delayMs > 1500 {
                self.logConnectionDiagnostics(
                    event: "account_queue_heartbeat_delayed",
                    details: [
                        "delayMs": delayMs,
                        "heartbeatID": id
                    ]
                )
            }

            guard self.connectionGate.snapshot().phase.isConnectionDiagnosticsHeartbeatActive else {
                return
            }
            self.scheduleConnectionDiagnosticsHeartbeat(id: id)
        }
    }

    private func isCurrentConnectionDiagnosticsHeartbeat(id: UInt64) -> Bool {
        connectionDiagnosticsLock.lock()
        defer { connectionDiagnosticsLock.unlock() }
        return connectionDiagnosticsHeartbeatID == id
    }

    private func shouldLogStartTLSStall(watchID: UInt64, attemptID: UInt64?) -> Bool {
        connectionDiagnosticsLock.lock()
        let isCurrentWatch = startTLSStallWatchID == watchID
        let callbackObserved = startTLSDelegateCallbackWatchID == watchID
        connectionDiagnosticsLock.unlock()

        guard isCurrentWatch, !callbackObserved else { return false }
        let snapshot = self.connectionGate.snapshot()
        guard snapshot.phase == .tlsNegotiating else { return false }
        if let attemptID {
            return snapshot.activeAttemptID == attemptID
        }
        return true
    }
    
/**
 *    open XMPPStream in special thread
 **/
    func asyncConnect(shouldReregisterDFevice: Bool = false, trigger: AccountConnectTrigger = .initialLoad) {
        let connectTrigger: AccountConnectTrigger = shouldReregisterDFevice ? .deviceReregister : trigger
        DDLogDebug("account async connect jid=\(self.jid) trigger=\(connectTrigger.rawValue) reregisterDevice=\(shouldReregisterDFevice) deviceIdPresent=\(self.devices.deviceId?.isEmpty == false) manualHost=\(self.manuallySetHost) hostPresent=\(self.host.isEmpty == false) port=\(self.port) resourcePresent=\(self.resource.isEmpty == false) phase=\(self.connectionGate.snapshot().phase.rawValue) streamState=\(self.streamStateDescription)")
        self.logConnectionDiagnostics(
            event: "async_connect_requested",
            trigger: connectTrigger,
            details: [
                "reregisterDevice": shouldReregisterDFevice,
                "deviceIdPresent": self.devices.deviceId?.isEmpty == false,
                "manualHost": self.manuallySetHost,
                "hostPresent": self.host.isEmpty == false,
                "port": self.port,
                "resourcePresent": self.resource.isEmpty == false
            ]
        )
        if shouldReregisterDFevice {
            if let deviceId = self.devices.deviceId {
                self.logConnectionDiagnostics(
                    event: "device_reregister_reset_stream",
                    trigger: connectTrigger,
                    details: ["deviceIdPresent": deviceId.isEmpty == false]
                )
                self.resetStream()
                self.xmppStream.xabberDeviceId = deviceId
                self.sm.storage.removeAll(for: self.xmppStream)
                self.smStorage.removeAll(for: self.xmppStream)
                self.smStorage.setResumptionId(nil, timeout: 0, lastDisconnect: nil, for: self.xmppStream)
            }
        }
        self.requestConnect(
            trigger: connectTrigger,
            forceReset: shouldReregisterDFevice,
            prepareStream: { self.configureStream() }
        )
    }
    
/**
 *    stop user XMPP session, change account status to offline
 *    if @hard is true, session close without sending unavailable presence to server
 **/
    func disconnect(hard: Bool = false, cause: AccountDisconnectCause? = nil) {
        let wasDisconnected = self.xmppStream.isDisconnected
        let resolvedCause = cause ?? .intentionalShutdown
        self.pendingDisconnectCause = resolvedCause
        self.sendReadiness.markDisconnected(cause: resolvedCause)
        self.sendCoordinator.streamDidDisconnect(canResume: self.sm.canResumeStream())
        self.primaryStreamStanzaTracker.noteStreamDidDisconnect(canResume: self.sm.canResumeStream())
        DDLogDebug("account disconnect requested jid=\(self.jid) hard=\(hard) cause=\(resolvedCause.rawValue) phase=\(self.connectionGate.snapshot().phase.rawValue) streamState=\(self.streamStateDescription)")
        self.logConnectionDiagnostics(
            event: "disconnect_requested",
            details: [
                "hard": hard,
                "wasDisconnected": wasDisconnected,
                "cause": resolvedCause.rawValue
            ]
        )
        self.cancelDelayedConnectTimer()
        if resolvedCause.isIntentional {
            self.reconnect.autoReconnect = false
        }
        AccountManager.shared.markAsNotConnecting(
            jid: self.jid,
            reason: resolvedCause.rawValue,
            clearAuthentication: true
        )
        if wasDisconnected {
            self.connectionGate.markDisconnected()
            self.connectionResilience.streamDidDisconnect(cause: resolvedCause)
            DDLogDebug("account disconnect completed locally jid=\(self.jid) hard=\(hard) reason=streamAlreadyDisconnected")
            self.logConnectionDiagnostics(
                event: "disconnect_completed_local",
                details: [
                    "hard": hard,
                    "reason": "streamAlreadyDisconnected",
                    "cause": resolvedCause.rawValue
                ]
            )
        } else {
            self.connectionGate.markDisconnecting()
        }
        self.statusState.accept(.offline)
        self.statusMessage.accept(RosterUtils.shared.convertStatus(.offline))
        self.resetModules()
        XMPPUIActionManager.shared.close(disconnect: true)
        if hard {
            guard !wasDisconnected else { return }
            self.xmppStream.disconnect()
//            self.xmppStream.asyncSocket.disconnect()
        } else {
            if resolvedCause.isIntentional {
                self.reconnect.autoReconnect = false
            }
            guard !wasDisconnected else { return }
            self.sendPrimaryStanza(
                XMPPPresence(type: .unavailable),
                replayPolicy: .latestPresence(scope: "account-unavailable")
            )
            self.xmppStream.disconnectAfterSending()
//            self.xmppStream.asyncSocket.disconnectAfterReadingAndWriting()
        }
    }
    
/**
 *    update presence status by last setted in settings
 **/
    private func deferPresenceUntilReady(_ opponentJid: XMPPJID?) {
        if let opponentJid {
            pendingPresenceTargetJids.insert(opponentJid.full)
        } else {
            shouldSendBroadcastPresenceWhenReady = true
            pendingPresenceTargetJids.removeAll()
        }
        self.logConnectionDiagnostics(
            event: "presence_deferred_until_send_ready",
            details: [
                "target": opponentJid?.full ?? "broadcast",
                "sendReady": self.sendReadiness.snapshot.canFlushApplicationStanzas
            ]
        )
    }

    private func flushPendingPresenceSends() {
        let shouldBroadcast = shouldSendBroadcastPresenceWhenReady
        let targetJids = pendingPresenceTargetJids
        shouldSendBroadcastPresenceWhenReady = false
        pendingPresenceTargetJids.removeAll()

        if shouldBroadcast {
            presence(nil)
            return
        }
        targetJids
            .compactMap { XMPPJID(string: $0) }
            .forEach { presence($0) }
    }

    func presence(_ opponentJid: XMPPJID? = nil) {
        guard self.sendReadiness.snapshot.canFlushApplicationStanzas else {
            deferPresenceUntilReady(opponentJid)
            return
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm
                .object(ofType: AccountStorageItem.self,
                        forPrimaryKey: self.jid)?
                .resource {
                self.presences.updateMyself(self.xmppStream,
                                            with: instance,
                                            ver: self.disco.generateVer(),
                                            to: opponentJid)
                self.statusState.accept(instance.status)
                self.statusMessage.accept(instance.statusMessage.isNotEmpty ? instance.statusMessage : RosterUtils.shared.convertStatus(instance.status))
            } else {
                let instance = ResourceStorageItem()
                instance.owner = self.jid
                instance.jid = self.jid
                instance.isCurrentResourceForAccount = true
                instance.resource = self.resource
                instance.client = ""
                instance.priority = 0
                instance.status = .online
                instance.statusMessage = ""
                instance.isTemporary = false
                instance.primary = ResourceStorageItem.genPrimary(jid: self.jid, owner: self.jid, resource: self.resource)
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.add(instance, update: .modified)
                        realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.resource = instance
                    }
                }
                self.presences.updateMyself(xmppStream, with: instance, ver: self.disco.generateVer(), to: opponentJid)
                self.statusState.accept(.online)
                self.statusMessage.accept(RosterUtils.shared.convertStatus(.online))
            }
        } catch {
            DDLogDebug("cant load status item instance for jid \(self.jid)")
        }
    }
    
/**
 *    update account status in subscription, in realm instance and send XMPPPresence to server
 **/
    func updateStatus(_ newStatus: ResourceStatus, with newMessage: String?) {
        func send(_ instance: ResourceStorageItem) {
            if newStatus == .offline {
                return
            } else {
                if self.sendReadiness.snapshot.canFlushApplicationStanzas {
                    if newMessage == nil {
                        self.statusMessage.accept(RosterUtils.shared.convertStatus(newStatus))
                    } else {
                        self.statusMessage.accept(newMessage!.isNotEmpty ? newMessage! : RosterUtils.shared.convertStatus(newStatus))
                    }
                    self.statusState.accept(newStatus)
                    self.presences.updateMyself(self.xmppStream,
                                                with: instance,
                                                ver: self.disco.generateVer(),
                                                to: nil)
                } else {
                    self.deferPresenceUntilReady(nil)
                    if !self.xmppStream.isAuthenticated {
                        self.asyncConnect(trigger: .statusUpdate)
                    }
                }
            }
        }
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: ResourceStorageItem.self, forPrimaryKey: [jid, resource, jid].prp()) {
                if newStatus != .offline {
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            instance.status = newStatus
                            instance.statusMessage = newMessage ?? ""
                            instance.timestamp = Date()
                            instance.isCurrentResourceForAccount = true
                        }
                    }
                }
                send(instance)
            } else {
                if newStatus != .offline {
                    let instance = ResourceStorageItem()
                    instance.owner = jid
                    instance.jid = jid
                    instance.isCurrentResourceForAccount = true
                    instance.resource = resource
                    instance.status = newStatus
                    instance.statusMessage = newMessage ?? ""
                    instance.timestamp = Date()
                    instance.isTemporary = false
                    instance.primary = ResourceStorageItem.genPrimary(jid: jid, owner: jid, resource: resource)
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            realm.add(instance, update: .modified)
                            realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.resource = instance
                        }
                    }
                    send(instance)
                }
            }
        } catch {
            DDLogDebug("cant update presence for account \(jid)")
        }
    }
    
/**
 *    sets configs and flags to initial state
 *    calls after any kind of disconnect
 **/
    func resetConfigs() {
        self.isRequestedAway = false
        self.isInitialMAMRequestSend = false
        self.ping.resetState()
    }
    
/**
 *    sets modules to initial state
 *    calls after any kind of disconnect
 **/
    func resetModules() {
//        self.statusMessage.accept("Waiting for network")
        self.statusMessage.accept("Offline")
        self.xmppTaskScheduler.reset()
        self.mam.didResetState()
        self.presences.didResetState()
        self.msgDeleteManager.clearSession()
        self.devices.clearSession()
        self.groupchats.reset()
        self.syncManager.reset()
    }

/**
 *    returns account status based on XMPPStream state
 **/
    func status() -> ResourceStatus {
        if self.xmppStream.isAuthenticated {
            return ResourceStatus.online
        } else {
            return ResourceStatus.offline
        }
    }
    
/**
 *    sends request to XMPP Message archive (XEP-0313)
 *    if its first request for account, it perform request for all contacts in roster by 1 message
 *    if it calls after initial state, when some last chats are exists,
 *    it perform request from last message delivery date to current moment by 50 message.
 *    if query size more than contains in one page, all other chats updates by individual request by 1 message
 **/
    func requestInitialMAM() {
//        if mam.isInitialArchiveRequested {
//            mam.requestAfterLastMessage(xmppStream, sync: true)
//        } else {
//            mam.requestForRoster(xmppStream)
//        }
        self.isInitialMAMRequestSend = true
        self.isRequestedAway = true
    }
    
/**
 *    used by push notification
 *    when push notification come, method compare last away date with current moment
 **/
    
//    func syncForPush() {
//        mam.requestAfterLastMessage(xmppStream, sync: false)
//    }
    
/**
 *    get stored properties about account from Realm
 **/
    func load() {
        do {
            let realm = try  WRealm.safe()
            if let item = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.jid) {
                self.jid = item.jid
                self.host = item.host
                self.supportTokens = item.xTokenSupport
                self.tokenUid = item.xTokenUID
                self.savePassword = item.savePassword
                self.manuallySetHost = item.manuallySetHost
                self.port = item.port
                self.deviceName = item.deviceName
                if let resource = item.resource?.resource {
                    self.resource = resource
                }
                self.username = item.username
                self.push.node = item.node
                self.push.service = item.service
            }
            if  self.deviceName.isEmpty {
                self.deviceName = NickGenerator.shared.genRandomNick()
            }
        } catch {
            DDLogDebug("cant load user \(self.jid) from db")
        }
    }
    
/**
 *    to enable push notification, you need register on App server
 *    response of App server contains information about node and service
 *    calls to update push service information
 *    @node - address, which associated with your jid on pubsub
 *    @service - jid of pubsub, which should send push notification to App server
 *    this properties must update at done of any auth process for account
 *    but, client can use stored in Realm properties values
 **/
    func update(forPushNode node: String, withService service: String) {
        self.push.configure(node: node, service: service)
        do {
            let realm = try  WRealm.safe()
            if let item = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.jid) {
                try realm.write {
                    item.node = node
                    item.service = service
                }
            }
        } catch {
            DDLogDebug("cant update push info for user \(jid)")
        }
    }
    
/**
 *    save token to keychain, override password
 */

    
/**
 *    change username and store it in db
 **/
    func updateUsername(_ username: String) {
        self.username = username
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: self.jid) {
                if !realm.isInWriteTransaction {
                    try realm.write {
                        instance.username = username
                    }
                }
            }
        } catch {
            DDLogDebug("cant change username for account \(self.jid)")
        }
    }
    
/**
 *    update creditionals and make reconnect. if success, error message is nil
 **/
    func updateResource(_ resource: String, callback: ((String?) -> Void)? = nil) {
        print(#function)
        disconnect(hard: true, cause: .resourceUpdate)
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: ResourceStorageItem.self,
                                           forPrimaryKey: [self.jid, self.resource, self.jid].prp()) {
                let newStatus = ResourceStorageItem()
                newStatus.owner = jid
                newStatus.jid = jid
                newStatus.isCurrentResourceForAccount = true
                newStatus.resource = resource
                let status = instance.status_
                let message = instance.statusMessage
                let priority = instance.priority
                newStatus.status_ = status
                newStatus.statusMessage = message
                newStatus.priority = priority
                newStatus.isTemporary = false
                newStatus.primary = ResourceStorageItem.genPrimary(jid: jid, owner: jid, resource: resource)
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.delete(instance)
                        realm.add(newStatus, update: .all)
                        realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.resource = newStatus
                    }
                }
            } else {
                let instance = ResourceStorageItem()
                instance.owner = jid
                instance.jid = jid
                instance.isCurrentResourceForAccount = true
                instance.resource = resource
                instance.status_ = ResourceStatus.online.rawValue
                instance.statusMessage = ""
                instance.priority = 0
                instance.isTemporary = false
                instance.primary = ResourceStorageItem.genPrimary(jid: jid, owner: jid, resource: resource)
                if !realm.isInWriteTransaction {
                    try realm.write {
                        realm.add(instance, update: .modified)
                        realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.resource = instance
                    }
                }
            }
        } catch {
            DDLogDebug("cant update creditionals for account \(jid)")
            callback?("Error during password or resource update".localizeString(id: "error_during_password_resource_update", arguments: []))
        }
        self.resource = resource.isEmpty ? AccountManager.defaultResource : resource
        self.asyncConnect(trigger: .resourceUpdate)
        callback?(nil)
    }
    
/**
 *    save account properties in Realm
 **/
    func create() {
        autoreleasepool {
            do {
                let realm = try  WRealm.safe()
                let item = AccountStorageItem()
                item.order = realm.objects(AccountStorageItem.self).count
                item.jid = self.jid
                item.host = self.host
                item.savePassword = self.savePassword
                item.manuallySetHost = self.manuallySetHost
                item.port = self.port
                if CommonConfigManager.shared.config.locked_account_color.isNotEmpty {
                    item.colorKey = CommonConfigManager.shared.config.locked_account_color
                } else {
                    item.colorKey = AccountColorManager.shared.colorItem(for: self.jid).key
                }
                
                item.username = self.username
                item.node = self.push.node
                item.service = self.push.service
                item.statusMessage = self.statusMessage.value
                item.xTokenSupport = self.supportTokens
                item.xTokenUID = self.tokenUid
                item.createdAt = Date()
                
                item.deviceName = self.deviceName
                if let deviceId = self.devices.deviceId {
                    item.deviceUuid = deviceId
                }
                
                try realm.write {
                    realm.add(item, update: .modified)
                }
            } catch {
                DDLogDebug("cant update push info for user \(self.jid)")
            }
        }
    }
    
    func disable() {
        self.xmppStream.removeDelegate(self)
        self.push.disable(xmppStream: xmppStream)
        APNSManager.shared.sendDeleteRequest(jid: jid, voip: true)
        APNSManager.shared.sendDeleteRequest(jid: jid, voip: false)
        PushNotificationsManager.removeDefaultsForPush(target: push.node, jid: jid)
        self.disconnect(hard: false, cause: .intentionalShutdown)
    }
    
/**
 *    delete all stored data
 **/
    func dropData() {
        self.xmppStream.removeDelegate(self)
        if self.supportTokens {
            self.xTokens.revoke(self.xmppStream, uids: [self.tokenUid])
        }
        self.disconnect(hard: false, cause: .accountDeletion)
    }
    
    static func remove(for owner: String, commitTransaction: Bool) {
        APNSManager.shared.sendDeleteRequest(jid: owner, voip: true)
        APNSManager.shared.sendDeleteRequest(jid: owner, voip: false)
        let keychain = KeychainWrapper(serviceName: CredentialsManager.uniqueServiceName(),
                                       accessGroup: CredentialsManager.uniqueAccessGroup())
        
        _ = keychain.removeObject(forKey: owner)
        _ = keychain.removeObject(forKey: [owner, "token"].prp())
        do {
            let realm = try  WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner) {
                PushNotificationsManager.removeDefaultsForPush(target: instance.node, jid: owner)
                if commitTransaction {
                    if !realm.isInWriteTransaction {
                        try realm.write {
                            if instance.isInvalidated { return }
                            realm.delete(instance)
                        }
                    }
                } else {
                    if instance.isInvalidated { return }
                    realm.delete(instance)
                }
            }
        } catch {
            DDLogDebug("cant delete server disco for account \(owner)")
        }
    }
    
/**
 *    delete stored messages
 *    @jid - remove messages for contact of account
 *    @forAll - remove all messages for account
 **/
    func removeMessages(forJid jid: String = "", commitTransaction: Bool) {
        do {
            let realm = try  WRealm.safe()
            var messages = realm.objects(MessageStorageItem.self).filter("owner == %@", self.jid)
            if jid.isNotEmpty {
                messages = messages.filter("opponent == %@", jid)
            }
//            var attaches: [MessageAttachmentStorageItem] = []
            var stanzas: [MessageStanzaStorageItem] = []
            messages.forEach {
                message in
                if let instance = realm.object(ofType: MessageStanzaStorageItem.self, forPrimaryKey: "\(message.primary)_stanza") {
                    stanzas.append(instance)
                }
            }
            let inlines = realm.objects(MessageForwardsInlineStorageItem.self).filter("owner == %@", self.jid)
            let refs = realm.objects(MessageReferenceStorageItem.self).filter("owner == %@", self.jid)
            var calls = realm.objects(CallMetadataStorageItem.self).filter("owner == %@", self.jid)
            if jid.isNotEmpty {
                calls = calls.filter("opponent == %@", jid)
            }
            if commitTransaction {
                try realm.write {
                    realm.delete(messages)
                    realm.delete(inlines)
                    realm.delete(refs)
                    realm.delete(stanzas)
                    realm.delete(calls)
                }
            } else {
                realm.delete(messages)
                realm.delete(inlines)
                realm.delete(refs)
                realm.delete(stanzas)
                realm.delete(calls)
            }
            
        } catch {
            DDLogDebug("cant remove messages for account \(self.jid)")
        }
    }

/**
 *    change state flag of push service for account and notify all subscribers
 **/
    func setPushState(state: Bool, callback: ()->Void) {
        self.pushWasReceived = state
        callback()
    }

/**
 *    set completion handler for catch end of push notification message loader
 **/
    func setCompletionHandler(completionHandler: (() -> Void)?) {
        self.completionHandler = completionHandler
    }

    func initiateCompleteRequest() {
        if self.completionHandlerTimer != nil {
            self.completionHandlerTimer!.invalidate()
            self.completionHandlerTimer = nil
        }
    }

/**
 *    notify application, that all messages, downloaded by push notify request, has been saved
 **/
    @objc func callCompletionHandler() {
        if self.completionHandler != nil {
            self.pushWasReceived = false
            self.completionHandler!()
            DDLogDebug("call completion handler")
        }
    }
    
/**
 *    emulate point to perform action from account
 *    example -
 *    user.action {
 *       (user, xmppStream) in
 *       your code here
 *    }
 **/
    func action(_ toExecute: @escaping ((Account, XMPPStream) -> Void)) {
        self.queue.async {
//            [unowned self] in
            toExecute(self, self.xmppStream)
        }
    }
    
    func delayedAction(delay: TimeInterval, toExecute: @escaping ((Account, XMPPStream) -> Void)) {
        DispatchQueue(
            label: "com.xabber.action.delayed.\(jid).\(UUID().uuidString)",
            qos: .background,
            attributes: .concurrent,
            autoreleaseFrequency: .workItem,
            target: nil
        ).asyncAfter(deadline: .now() + delay ) {
            [weak self] in
            guard let self else { return }
            toExecute(self, self.xmppStream)
        }
    }
    
    func unsafeAction(_ toExecute: @escaping (Account, XMPPStream) -> Void) {
        toExecute(self, self.xmppStream)
    }
}

extension Account: XMPPReconnectDelegate {
    func showReconnectStatus(connectionFlags: SCNetworkConnectionFlags) {
        switch connectionFlags{
        case UInt32(kSCNetworkFlagsTransientConnection):
            DDLogDebug("kSCNetworkFlagsTransientConnection")
            break
        case UInt32(kSCNetworkFlagsReachable):
            DDLogDebug("kSCNetworkFlagsReachable")
            break
        case UInt32(kSCNetworkFlagsConnectionRequired):
            DDLogDebug("kSCNetworkFlagsConnectionRequired")
            break
        case UInt32(kSCNetworkFlagsConnectionAutomatic):
            DDLogDebug("kSCNetworkFlagsConnectionAutomatic")
            break
        case UInt32(kSCNetworkFlagsInterventionRequired):
            DDLogDebug("kSCNetworkFlagsInterventionRequired")
            break
        case UInt32(kSCNetworkFlagsIsLocalAddress):
            DDLogDebug("kSCNetworkFlagsIsLocalAddress")
            break
        case UInt32(kSCNetworkFlagsIsDirect):
            DDLogDebug("kSCNetworkFlagsIsDirect")
            break
        default:
            DDLogDebug("none flag")
        }
    }
    
    func xmppReconnect(_ sender: XMPPReconnect, didDetectAccidentalDisconnect connectionFlags: SCNetworkConnectionFlags) {
        DDLogDebug("DidDetectDisconnect. Connection flags \(connectionFlags)")
        self.logConnectionDiagnostics(
            event: "reconnect_detected_accidental_disconnect",
            details: ["connectionFlags": UInt32(connectionFlags)]
        )
        self.resetModules()
        self.statusMessage.accept("Offline")
        self.showReconnectStatus(connectionFlags: connectionFlags)
        AccountManager.shared.markAsConnecting(jid: self.jid)
        self.connectionResilience.scheduleReconnect(cause: .accidentalSocket, trigger: .resilienceRetry)
    }
    
    func xmppReconnect(_ sender: XMPPReconnect, shouldAttemptAutoReconnect connectionFlags: SCNetworkConnectionFlags) -> Bool {
        DDLogDebug("ShouldAttemptAutoReconnect. Connection flags \(connectionFlags)")
        self.logConnectionDiagnostics(
            event: "reconnect_should_attempt",
            trigger: .xmppReconnect,
            details: [
                "connectionFlags": UInt32(connectionFlags),
                "autoReconnect": sender.autoReconnect
            ]
        )
//        if UInt32(connectionFlags) == 3 {
//            return false
//        }
//        self.showReconnectStatus(connectionFlags: connectionFlags)
//        DispatchQueue.main.async {
//            ToastPresenter(message: "Reconnect: flag \(UInt32(connectionFlags))").present(animated: true)
//        }
        if self.xmppStream.isAuthenticated {
            self.logConnectionDiagnostics(
                event: "reconnect_skipped_authenticated",
                trigger: .xmppReconnect,
                details: ["connectionFlags": UInt32(connectionFlags)]
            )
            return false
        }
        if self.xmppStream.isConnected || self.xmppStream.isConnecting || self.xmppStream.isAuthenticating {
            DDLogDebug("skip duplicate account reconnect jid=\(self.jid) streamState=\(self.streamStateDescription)")
            self.logConnectionDiagnostics(
                event: "reconnect_skipped_stream_active",
                trigger: .xmppReconnect,
                details: ["connectionFlags": UInt32(connectionFlags)]
            )
            return false
        }

        guard sender.autoReconnect else {
            self.logConnectionDiagnostics(
                event: "reconnect_skipped_disabled",
                trigger: .xmppReconnect,
                details: ["connectionFlags": UInt32(connectionFlags)]
            )
            return false
        }

        switch self.connectionGate.beginConnect(trigger: .xmppReconnect) {
        case .start(let attemptID):
            DDLogDebug("primary stream reconnect jid=\(self.jid) attempt=\(attemptID)")
            self.logConnectionDiagnostics(
                event: "reconnect_allowed",
                attemptID: attemptID,
                trigger: .xmppReconnect,
                details: ["connectionFlags": UInt32(connectionFlags)]
            )
            self.beginConnectionDiagnosticsHeartbeat()
            AccountManager.shared.markAsConnecting(jid: self.jid)
            return true

        case .skip(let phase, let activeAttemptID):
            DDLogDebug("skip duplicate account reconnect jid=\(self.jid) phase=\(phase.rawValue) attempt=\(activeAttemptID.map(String.init) ?? "none")")
            self.logConnectionDiagnostics(
                event: "reconnect_skipped_gate",
                trigger: .xmppReconnect,
                phase: phase,
                details: [
                    "connectionFlags": UInt32(connectionFlags),
                    "activeAttempt": activeAttemptID.map(String.init) ?? "none"
                ]
            )
            return false
        }
    }
    
}
