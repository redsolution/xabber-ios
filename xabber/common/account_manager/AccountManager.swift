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
import RealmSwift
import RxSwift
import RxCocoa
import CocoaLumberjack
import SwiftKeychainWrapper
import Kingfisher

enum AccountDeletionDiagnosticsEventName: String, Equatable {
    case started = "account_deletion_started"
    case finished = "account_deletion_finished"
    case failed = "account_deletion_failed"
}

enum AccountDeletionCleanupStage: String, Equatable {
    case preRealmCleanup
    case storageCleanup
    case postCleanup
}

enum AccountDeletionUIActionClosePolicy {
    static func closeSoftFlag(hard: Bool) -> Bool {
        !hard
    }
}

enum AccountDeletionCredentialCleanupPolicy {
    static func shouldClearSharedKeychain(supportsMultiaccounts: Bool) -> Bool {
        !supportsMultiaccounts
    }
}

public enum AccountCreationResult: Equatable {
    case created
    case alreadyExists
}

struct AccountDeletionCleanupResult: Equatable {
    let jid: String
    let hard: Bool
    let succeeded: Bool
    let failedStage: AccountDeletionCleanupStage?
    let errorDescription: String?
    let storageInvokedOnMainThread: Bool?

    static func success(
        jid: String,
        hard: Bool,
        storageInvokedOnMainThread: Bool
    ) -> AccountDeletionCleanupResult {
        AccountDeletionCleanupResult(
            jid: jid,
            hard: hard,
            succeeded: true,
            failedStage: nil,
            errorDescription: nil,
            storageInvokedOnMainThread: storageInvokedOnMainThread
        )
    }

    static func failure(
        jid: String,
        hard: Bool,
        failedStage: AccountDeletionCleanupStage,
        error: Error,
        storageInvokedOnMainThread: Bool?
    ) -> AccountDeletionCleanupResult {
        AccountDeletionCleanupResult(
            jid: jid,
            hard: hard,
            succeeded: false,
            failedStage: failedStage,
            errorDescription: Self.errorDescription(from: error),
            storageInvokedOnMainThread: storageInvokedOnMainThread
        )
    }

    private static func errorDescription(from error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

struct AccountDeletionCleanupOperations {
    let preRealmCleanup: () throws -> Void
    let storageCleanup: () throws -> Void
    let postCleanup: () throws -> Void
}

final class AccountDeletionCleanupCoordinator {
    typealias Queue = (@escaping () -> Void) -> Void

    private static let defaultStorageQueue = DispatchQueue(
        label: "com.xabber.account-deletion.storage",
        qos: .userInitiated
    )

    private let storageQueue: Queue
    private let completionQueue: Queue

    init(
        storageQueue: @escaping Queue = { work in
            AccountDeletionCleanupCoordinator.defaultStorageQueue.async(execute: work)
        },
        completionQueue: @escaping Queue = { work in
            DispatchQueue.main.async(execute: work)
        }
    ) {
        self.storageQueue = storageQueue
        self.completionQueue = completionQueue
    }

    func runSynchronously(
        jid: String,
        hard: Bool,
        operations: AccountDeletionCleanupOperations
    ) -> AccountDeletionCleanupResult {
        do {
            try operations.preRealmCleanup()
        } catch {
            return .failure(
                jid: jid,
                hard: hard,
                failedStage: .preRealmCleanup,
                error: error,
                storageInvokedOnMainThread: nil
            )
        }

        let storageInvokedOnMainThread = Thread.isMainThread
        do {
            try operations.storageCleanup()
        } catch {
            return .failure(
                jid: jid,
                hard: hard,
                failedStage: .storageCleanup,
                error: error,
                storageInvokedOnMainThread: storageInvokedOnMainThread
            )
        }

        do {
            try operations.postCleanup()
        } catch {
            return .failure(
                jid: jid,
                hard: hard,
                failedStage: .postCleanup,
                error: error,
                storageInvokedOnMainThread: storageInvokedOnMainThread
            )
        }

        return .success(
            jid: jid,
            hard: hard,
            storageInvokedOnMainThread: storageInvokedOnMainThread
        )
    }

    func runAsync(
        jid: String,
        hard: Bool,
        operations: AccountDeletionCleanupOperations,
        completion: @escaping (AccountDeletionCleanupResult) -> Void
    ) {
        do {
            try operations.preRealmCleanup()
        } catch {
            completionQueue {
                completion(
                    .failure(
                        jid: jid,
                        hard: hard,
                        failedStage: .preRealmCleanup,
                        error: error,
                        storageInvokedOnMainThread: nil
                    )
                )
            }
            return
        }

        storageQueue { [completionQueue] in
            let storageInvokedOnMainThread = Thread.isMainThread
            do {
                try operations.storageCleanup()
            } catch {
                completionQueue {
                    completion(
                        .failure(
                            jid: jid,
                            hard: hard,
                            failedStage: .storageCleanup,
                            error: error,
                            storageInvokedOnMainThread: storageInvokedOnMainThread
                        )
                    )
                }
                return
            }

            completionQueue {
                do {
                    try operations.postCleanup()
                } catch {
                    completion(
                        .failure(
                            jid: jid,
                            hard: hard,
                            failedStage: .postCleanup,
                            error: error,
                            storageInvokedOnMainThread: storageInvokedOnMainThread
                        )
                    )
                    return
                }

                completion(
                    .success(
                        jid: jid,
                        hard: hard,
                        storageInvokedOnMainThread: storageInvokedOnMainThread
                    )
                )
            }
        }
    }
}

enum AccountDeletionStorageCleanupKind: Equatable {
    case account
    case vCards
    case messages
    case presence
    case deviceSessionCredentials
    case groupchats
    case recentChats
    case clientSynchronization
    case blocks
    case serverDiscovery
    case roster
    case messageDeletes
    case reliableDelivery
    case omemo
    case certificates
    case notifications
    case favorites
    case authenticatedKeyExchange
    case subscriptions

    static var defaultOrder: [AccountDeletionStorageCleanupKind] {
        AccountDeletionStorageCleanupStep.defaultSteps.map(\.kind)
    }
}

struct AccountDeletionStorageCleanupStep {
    let kind: AccountDeletionStorageCleanupKind
    let perform: (_ jid: String) -> Void

    static let defaultSteps: [AccountDeletionStorageCleanupStep] = [
        AccountDeletionStorageCleanupStep(kind: .account) {
            Account.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .vCards) {
            VCardManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .messages) {
            MessageManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .presence) {
            PresenceManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .deviceSessionCredentials) {
            XTokenManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .groupchats) {
            GroupchatManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .recentChats) {
            LastChats.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .clientSynchronization) {
            ClientSynchronizationManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .blocks) {
            BlockManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .serverDiscovery) {
            ServerDiscoManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .roster) {
            RosterManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .messageDeletes) {
            MessageDeleteManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .reliableDelivery) {
            ReliableMessageDeliveryManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .omemo) {
            OmemoManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .certificates) {
            X509XMPPManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .notifications) {
            XMPPNotificationsManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .favorites) {
            XMPPFavoritesManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .authenticatedKeyExchange) {
            AuthenticatedKeyExchangeManager.remove(for: $0, commitTransaction: false)
        },
        AccountDeletionStorageCleanupStep(kind: .subscriptions) {
            SubscribtionsManager.shared.remove(for: $0, commitTransaction: false)
        }
    ]
}

struct AccountDeletionDiagnosticsEvent {
    let name: AccountDeletionDiagnosticsEventName
    let jid: String
    let hard: Bool
    let invokedOnMainThread: Bool
    let totalDurationMs: Int?
    let preRealmCleanupMs: Int?
    let realmWriteMs: Int?
    let postCleanupMs: Int?
    let succeeded: Bool?
    let failedStage: AccountDeletionCleanupStage?
    let storageInvokedOnMainThread: Bool?

    init(
        name: AccountDeletionDiagnosticsEventName,
        jid: String,
        hard: Bool,
        invokedOnMainThread: Bool,
        totalDurationMs: Int?,
        preRealmCleanupMs: Int?,
        realmWriteMs: Int?,
        postCleanupMs: Int?,
        succeeded: Bool? = nil,
        failedStage: AccountDeletionCleanupStage? = nil,
        storageInvokedOnMainThread: Bool? = nil
    ) {
        self.name = name
        self.jid = jid
        self.hard = hard
        self.invokedOnMainThread = invokedOnMainThread
        self.totalDurationMs = totalDurationMs
        self.preRealmCleanupMs = preRealmCleanupMs
        self.realmWriteMs = realmWriteMs
        self.postCleanupMs = postCleanupMs
        self.succeeded = succeeded
        self.failedStage = failedStage
        self.storageInvokedOnMainThread = storageInvokedOnMainThread
    }

    func diagnosticLine() -> String {
        ConnectionDiagnosticsLogger.line(
            event: name.rawValue,
            stream: .accountDelete,
            jid: jid,
            details: details
        )
    }

    func log() {
        ConnectionDiagnosticsLogger.log(
            event: name.rawValue,
            stream: .accountDelete,
            jid: jid,
            details: details
        )
    }

    private var details: [String: Any?] {
        [
            "failedStage": failedStage?.rawValue,
            "hard": hard,
            "invokedOnMainThread": invokedOnMainThread,
            "postCleanupMs": postCleanupMs,
            "preRealmCleanupMs": preRealmCleanupMs,
            "realmWriteMs": realmWriteMs,
            "storageInvokedOnMainThread": storageInvokedOnMainThread,
            "succeeded": succeeded,
            "totalDurationMs": totalDurationMs
        ]
    }
}

final class AccountDeletionDiagnosticsRecorder {
    typealias Clock = () -> TimeInterval
    typealias Sink = (AccountDeletionDiagnosticsEvent) -> Void

    static let live = AccountDeletionDiagnosticsRecorder(
        clock: { ProcessInfo.processInfo.systemUptime },
        sink: { $0.log() }
    )

    private let clock: Clock
    private let sink: Sink

    init(
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
        sink: @escaping Sink = { $0.log() }
    ) {
        self.clock = clock
        self.sink = sink
    }

    func begin(
        jid: String,
        hard: Bool,
        invokedOnMainThread: Bool = Thread.isMainThread
    ) -> AccountDeletionDiagnosticsSession {
        let startedAt = now()
        emit(
            AccountDeletionDiagnosticsEvent(
                name: .started,
                jid: jid,
                hard: hard,
                invokedOnMainThread: invokedOnMainThread,
                totalDurationMs: nil,
                preRealmCleanupMs: nil,
                realmWriteMs: nil,
                postCleanupMs: nil
            )
        )
        return AccountDeletionDiagnosticsSession(
            recorder: self,
            jid: jid,
            hard: hard,
            invokedOnMainThread: invokedOnMainThread,
            startedAt: startedAt
        )
    }

    fileprivate func now() -> TimeInterval {
        clock()
    }

    fileprivate func emit(_ event: AccountDeletionDiagnosticsEvent) {
        sink(event)
    }
}

struct AccountDeletionDiagnosticsSession {
    private let recorder: AccountDeletionDiagnosticsRecorder
    private let jid: String
    private let hard: Bool
    private let invokedOnMainThread: Bool
    private let startedAt: TimeInterval

    private var lastStageAt: TimeInterval
    private var preRealmCleanupMs: Int?
    private var realmWriteMs: Int?
    private var storageInvokedOnMainThread: Bool?
    private var didFinish: Bool = false

    init(
        recorder: AccountDeletionDiagnosticsRecorder,
        jid: String,
        hard: Bool,
        invokedOnMainThread: Bool,
        startedAt: TimeInterval
    ) {
        self.recorder = recorder
        self.jid = jid
        self.hard = hard
        self.invokedOnMainThread = invokedOnMainThread
        self.startedAt = startedAt
        self.lastStageAt = startedAt
    }

    mutating func markPreRealmCleanupFinished() {
        guard !didFinish else { return }
        let now = recorder.now()
        preRealmCleanupMs = Self.milliseconds(from: now - lastStageAt)
        lastStageAt = now
    }

    mutating func markRealmWriteFinished(invokedOnMainThread: Bool = Thread.isMainThread) {
        guard !didFinish else { return }
        let now = recorder.now()
        realmWriteMs = Self.milliseconds(from: now - lastStageAt)
        storageInvokedOnMainThread = invokedOnMainThread
        lastStageAt = now
    }

    mutating func finish() {
        guard !didFinish else { return }
        didFinish = true
        let now = recorder.now()
        recorder.emit(
            AccountDeletionDiagnosticsEvent(
                name: .finished,
                jid: jid,
                hard: hard,
                invokedOnMainThread: invokedOnMainThread,
                totalDurationMs: Self.milliseconds(from: now - startedAt),
                preRealmCleanupMs: preRealmCleanupMs,
                realmWriteMs: realmWriteMs,
                postCleanupMs: Self.milliseconds(from: now - lastStageAt),
                succeeded: true,
                storageInvokedOnMainThread: storageInvokedOnMainThread
            )
        )
    }

    mutating func fail(stage: AccountDeletionCleanupStage) {
        guard !didFinish else { return }
        didFinish = true
        let now = recorder.now()
        recorder.emit(
            AccountDeletionDiagnosticsEvent(
                name: .failed,
                jid: jid,
                hard: hard,
                invokedOnMainThread: invokedOnMainThread,
                totalDurationMs: Self.milliseconds(from: now - startedAt),
                preRealmCleanupMs: preRealmCleanupMs,
                realmWriteMs: realmWriteMs,
                postCleanupMs: Self.milliseconds(from: now - lastStageAt),
                succeeded: false,
                failedStage: stage,
                storageInvokedOnMainThread: storageInvokedOnMainThread
            )
        )
    }

    private static func milliseconds(from seconds: TimeInterval) -> Int {
        Int((max(0, seconds) * 1000).rounded())
    }
}

private final class AccountDeletionDiagnosticsSessionBox {
    private let lock = NSLock()
    private var session: AccountDeletionDiagnosticsSession

    init(session: AccountDeletionDiagnosticsSession) {
        self.session = session
    }

    func markPreRealmCleanupFinished() {
        update { $0.markPreRealmCleanupFinished() }
    }

    func markRealmWriteFinished(invokedOnMainThread: Bool) {
        update { $0.markRealmWriteFinished(invokedOnMainThread: invokedOnMainThread) }
    }

    func finish() {
        update { $0.finish() }
    }

    func fail(stage: AccountDeletionCleanupStage) {
        update { $0.fail(stage: stage) }
    }

    private func update(_ body: (inout AccountDeletionDiagnosticsSession) -> Void) {
        lock.lock()
        body(&session)
        lock.unlock()
    }
}

final class AccountManagerSnapshotStorage<Element> {
    private let lock = NSLock()
    private var elements: [Element]

    init(_ elements: [Element] = []) {
        self.elements = elements
    }

    func snapshot() -> [Element] {
        lock.lock()
        let result = elements
        lock.unlock()
        return result
    }

    func replace(with newElements: [Element]) {
        lock.lock()
        let displacedElements = elements
        elements = newElements
        lock.unlock()

        // Account teardown may re-enter AccountManager.find(for:). Keep removed
        // accounts alive until after the registry lock has been released.
        withExtendedLifetime(displacedElements) {}
    }

    func append(_ element: Element) {
        lock.lock()
        elements.append(element)
        lock.unlock()
    }

    @discardableResult
    func removeFirst(where predicate: (Element) -> Bool) -> Element? {
        lock.lock()
        let removedElement: Element?
        if let index = elements.firstIndex(where: predicate) {
            removedElement = elements.remove(at: index)
        } else {
            removedElement = nil
        }
        lock.unlock()

        // Returning the removed element guarantees that its destruction, which
        // may re-enter AccountManager, happens after the lock is released.
        return removedElement
    }
}

public class AccountManager: NSObject {
    
    enum Pipeline {
        case short
        case full
    }

    struct BackgroundChatUpdateTaskItem {
        let owner: String
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType
    }
    
    struct UserObserver {
        
        enum State {
            case none
            case startConnection
            case connect
            case auth
            case capsReceived([String])
            case dataLoaded
            case failure(String)
            case streamError(String)

            var diagnosticName: String {
                switch self {
                case .none: return "none"
                case .startConnection: return "startConnection"
                case .connect: return "connect"
                case .auth: return "auth"
                case .capsReceived: return "capsReceived"
                case .dataLoaded: return "dataLoaded"
                case .failure: return "failure"
                case .streamError: return "streamError"
                }
            }

            var isTerminalSignInState: Bool {
                switch self {
                case .capsReceived, .failure, .streamError:
                    return true
                case .none, .startConnection, .connect, .auth, .dataLoaded:
                    return false
                }
            }
        }
        
        let jid: String
        let state: State
        
    }
    
    static let defaultResource = "\(CommonConfigManager.shared.config.app_name.lowercased())-ios-\(String(describing: String(describing: UIDevice.current.identifierForVendor!).split(separator: "-").first!))"
    
    var newAccountJid: String = ""
    var newAccountObservable: BehaviorRelay<UserObserver> = BehaviorRelay(value: UserObserver(jid: "", state: .none))
    
    private let userStorage = AccountManagerSnapshotStorage<Account>()
    var users: [Account] {
        get { userStorage.snapshot() }
        set { userStorage.replace(with: newValue) }
    }
    var accountDeletionDiagnosticsRecorder: AccountDeletionDiagnosticsRecorder = .live
    
    var bag: DisposeBag = DisposeBag()
    var activeUsers: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    
    var xmppBackgroundTasks: [XMPPBackgroundTask] = []

    var authenticatedUsers: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    var connectingUsers: BehaviorRelay<Set<String>> = BehaviorRelay(value: Set<String>())
    
    var backgroundUpdateTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
    
    private var backgroundChatUpdateTaskItem: BackgroundChatUpdateTaskItem? = nil
    
    var alreadyLoaded: Bool = false
    
    open class var shared: AccountManager {
        struct AccountManagerSingleton {
            static let instance = AccountManager()
        }
        return AccountManagerSingleton.instance
    }

    override init() {
        super.init()
        addObservers()
    }

    private func updateActiveUsers(_ transform: @escaping (inout Set<String>) -> Void) {
        let apply = {
            var value = self.activeUsers.value
            transform(&value)
            self.activeUsers.accept(value)
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func updateConnectingUsers(_ transform: @escaping (inout Set<String>) -> Void) {
        let apply = {
            var value = self.connectingUsers.value
            transform(&value)
            self.connectingUsers.accept(value)
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func updateAuthenticatedUsers(_ transform: @escaping (inout Set<String>) -> Void) {
        let apply = {
            var value = self.authenticatedUsers.value
            transform(&value)
            self.authenticatedUsers.accept(value)
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
    
    private func addObservers() {
        NotificationCenter
            .default
            .addObserver(self,
                         selector: #selector(willEnterForeground),
                         name: UIApplication.willEnterForegroundNotification,
                         object: UIApplication.shared)

        NotificationCenter
            .default
            .addObserver(self,
                         selector: #selector(willEnterBackground),
                         name: UIApplication.didEnterBackgroundNotification,
                         object: UIApplication.shared)
    }
    
    public final func prepare() {
        
    }
    
    @objc
    private func willEnterForeground() {
        self.prepareForForeground()
//        let appDelegate = UIApplication.shared.delegate as? AppDelegate
//        appDelegate?.presentPasscodeOrRemoveBlurredScreen()
    }
    
    @objc
    private func willEnterBackground() {
        self.prepareForBackground()
//        let appDelegate = UIApplication.shared.delegate as? AppDelegate
//        appDelegate?.addBlurredScreen()
        self.users.forEach {
            $0.disconnect(hard: true, cause: .backgroundSuspension)
        }
        XMPPUIActionManager.shared.close(disconnect: true)
    }
    
    private func removeObservers() {
        NotificationCenter.default.removeObserver(self)
    }
    
    var updatedChats: Set<String> = Set()
    
    func addUpdatedChat(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) {
        self.updatedChats.insert([jid, owner, conversationType.rawValue].prp())
    }
    
    func checkIsChatUpdated(jid: String, owner: String, conversationType: ClientSynchronizationManager.ConversationType) -> Bool {
        return false//self.updatedChats.contains([jid, owner, conversationType.rawValue].prp())
    }
    
    func subscribe() {
        bag = DisposeBag()
        do {
            let realm = try WRealm.safe()
            Observable
                .collection(from: realm.objects(AccountStorageItem.self))
                .debounce(.seconds(1), scheduler: ConcurrentDispatchQueueScheduler(qos: .default))
                .subscribe(onNext: { (results) in
                    results.forEach {
                        let jid = $0.jid
                        if $0.enabled {
                            if !self.activeUsers.value.contains(jid) {
                                self.updateActiveUsers { value in
                                    value.insert(jid)
                                }
                            }
                        } else {
                            if self.activeUsers.value.contains(jid) {
                                self.updateActiveUsers { value in
                                    value.remove(jid)
                                }
                            }
                        }
                    }
                })
                .disposed(by: bag)
        } catch {
            DDLogDebug("cant create observer on account list")
        }
    }
    
    func emptyAccountsList() -> Bool {
        
        do {
            let realm = try WRealm.safe()
            return realm.objects(AccountStorageItem.self).isEmpty
        } catch {
            DDLogDebug("cant checked accounts count")
        }
        
        return true
    }
    
    func load(_ autoConnect: Bool = true) {
        do {
            let realm = try WRealm.safe()
            let jids = realm
                .objects(AccountStorageItem.self)
                .filter("enabled == %@", true)
                .toArray()
                .compactMap { return $0.jid }
            DDLogDebug("account manager load enabledCount=\(jids.count) autoConnect=\(autoConnect) existingUsers=\(self.users.count)")
            jids
                .forEach {
                    DDLogDebug("account manager load account jid=\($0) autoConnect=\(autoConnect) alreadyLoaded=\(self.find(for: $0) != nil)")
                    self.add(withJid: $0, autoConnect: autoConnect)
                }
        } catch {
            DDLogDebug("cant load accounts list from db")
        }
    }
    
    func find(for jid: String) -> Account? {
        return users.first(where: { $0.jid == jid })
    }
    
    @discardableResult
    public final func create(
        jid: String,
        password: String,
        nickname: String?,
        isFromRegister: Bool
    ) -> AccountCreationResult {
        guard !users.contains(where: { $0.jid == jid }) else {
            return .alreadyExists
        }

        self.newAccountJid = jid
        SettingManager.shared.clear(for: jid)
        self.changeNewUserState(for: jid, to: .none)
        let uniqueServiceName = CredentialsManager.uniqueServiceName()
        let uniqueAccessGroup = CredentialsManager.uniqueAccessGroup()
        let keychain = KeychainWrapper(serviceName: uniqueServiceName,
                                       accessGroup: uniqueAccessGroup)

        _ = keychain.removeObject(forKey: jid)
        _ = keychain.removeObject(forKey: [jid, "token"].prp())
        
        let queue = DispatchQueue(
            label: "com.xabber.stream.\(UUID().uuidString)",
            qos: .userInitiated,
            attributes: [],//[.concurrent],
            autoreleaseFrequency: .workItem,
            target: nil
        )
        
        CredentialsManager.shared.setItem(for: jid, password: password)
        
        self.markAsConnecting(jid: jid)
        let newAccount = Account(jid: jid, queue: queue)
        self.userStorage.append(newAccount)
        newAccount.asyncConnect(trigger: .initialLoad)

        if let nickname = nickname {
            newAccount.username = nickname
        }
        newAccount.savePassword = true
        newAccount.useSecureConnection = true
        newAccount.resource = AccountManager.defaultResource
        newAccount.create()
        newAccount.isNewAccount = isFromRegister
        return .created
    }
    
    func reloadAccount(withJid jid: String, autoConnect: Bool = true) {
        if let account = self.userStorage.removeFirst(where: { $0.jid == jid }) {
            account.disconnect(hard: true, cause: .intentionalShutdown)
        }
        self.add(withJid: jid, autoConnect: autoConnect)
    }
    
    func add(withJid jid: String, autoConnect: Bool = true) {
        if find(for: jid) != nil {
            if autoConnect {
                find(for: jid)?.restore()
            }
            return
        }
        
        self.markAsConnecting(jid: jid)
        let queue = DispatchQueue(
            label: "com.xabber.stream.\(jid).\(UUID().uuidString)",
            qos: .userInitiated,
            attributes: [],//[.concurrent],
            autoreleaseFrequency: .workItem,
            target: nil
        )

        let newAccount = Account(jid: jid, queue: queue)
        self.userStorage.append(newAccount)
        if autoConnect {
            newAccount.asyncConnect(trigger: .addExistingAccount)
        }
        let jids = Set(self.users.compactMap { $0.jid })
        let connectingUsers = self.connectingUsers.value
        connectingUsers.forEach {
            jid in
            if !jids.contains(jid) {
                self.markAsConnected(jid: jid)
            }
        }
    }
    
    func isExist(jid: String) -> Bool {
        do {
            let realm = try WRealm.safe()
            if realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) != nil {
                return false
            }
        } catch {
            DDLogDebug("cant get information about new user \(jid)")
        }
        return true
    }
    
    func enable(jid: String) {
        add(withJid: jid)
        do {
            let realm = try WRealm.safe()
            try realm.write {
                realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid)?.enabled = true
            }
        } catch {
            DDLogDebug("AccountManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    func disable(jid: String) {
        self.find(for: jid)?.disable()
        NotifyManager.shared.clearNotificationsFor(account: jid)
        do {
            _ = userStorage.removeFirst(where: { $0.jid == jid })
            let realm = try WRealm.safe()
            if let instance = realm.object(ofType: AccountStorageItem.self, forPrimaryKey: jid) {
                try realm.write {
                    instance.enabled = false
                    instance.node = ""
                    instance.service = ""
                }
            }
        } catch {
            DDLogDebug("AccountManager: \(#function). \(error.localizedDescription)")
        }
    }
    
    @discardableResult
    func deleteAccount(by jid: String, hard: Bool = true) -> AccountDeletionCleanupResult {
        let diagnosticsSession = AccountDeletionDiagnosticsSessionBox(
            session: accountDeletionDiagnosticsRecorder.begin(jid: jid, hard: hard)
        )
        let result = AccountDeletionCleanupCoordinator().runSynchronously(
            jid: jid,
            hard: hard,
            operations: accountDeletionCleanupOperations(
                jid: jid,
                hard: hard,
                diagnosticsSession: diagnosticsSession
            )
        )
        finishAccountDeletion(result, diagnosticsSession: diagnosticsSession)
        return result
    }

    func deleteAccountAsync(
        by jid: String,
        hard: Bool = true,
        completion: @escaping (AccountDeletionCleanupResult) -> Void
    ) {
        let diagnosticsSession = AccountDeletionDiagnosticsSessionBox(
            session: accountDeletionDiagnosticsRecorder.begin(jid: jid, hard: hard)
        )
        AccountDeletionCleanupCoordinator().runAsync(
            jid: jid,
            hard: hard,
            operations: accountDeletionCleanupOperations(
                jid: jid,
                hard: hard,
                diagnosticsSession: diagnosticsSession
            )
        ) { [weak self] result in
            self?.finishAccountDeletion(result, diagnosticsSession: diagnosticsSession)
            completion(result)
        }
    }

    private func accountDeletionCleanupOperations(
        jid: String,
        hard: Bool,
        diagnosticsSession: AccountDeletionDiagnosticsSessionBox
    ) -> AccountDeletionCleanupOperations {
        AccountDeletionCleanupOperations(
            preRealmCleanup: {
                self.performPreRealmAccountDeletionCleanup(jid: jid, hard: hard)
                diagnosticsSession.markPreRealmCleanupFinished()
            },
            storageCleanup: {
                try self.performStorageAccountDeletionCleanup(jid: jid)
                diagnosticsSession.markRealmWriteFinished(invokedOnMainThread: Thread.isMainThread)
            },
            postCleanup: {
                self.performPostRealmAccountDeletionCleanup(jid: jid)
            }
        )
    }

    private func performPreRealmAccountDeletionCleanup(jid: String, hard: Bool) {
        if XMPPUIActionManager.shared.currentJid == jid {
            XMPPUIActionManager.shared.close(
                soft: AccountDeletionUIActionClosePolicy.closeSoftFlag(hard: hard),
                disconnect: true
            )
            XMPPUIActionManager.shared.currentJid = nil
        }
        self.xmppBackgroundTasks.filter { $0.jid == jid }.forEach {
            $0.disconnect()
            $0.endBackgroundUpdateTask()
        }
        self.find(for: jid)?.unsafeAction({ user, stream in
            CredentialsManager.shared.removePushCredentials(for: user.push.node)
            user.devices.revoke(stream, uids: [user.devices.deviceId ?? ""])
            user.disconnect(hard: hard, cause: .accountDeletion)
        })
        changeNewUserState(for: jid, to: .none)
        NotifyManager.shared.clearNotificationsFor(account: jid)
        SettingManager.shared.clear(for: jid)
        APNSManager.shared.sendDeleteRequest(jid: jid, voip: false)
        APNSManager.shared.sendDeleteRequest(jid: jid, voip: true)
        self.find(for: jid)?.dropData()
        
        XabberUploadManager.removeToken(for: jid)
        CredentialsManager.shared.removeXabberAccountUUID(for: jid)
        CredentialsManager.shared.removeXabberAccountToken(for: jid)
        CredentialsManager.shared.removeXabberAccountTokenExpire(for: jid)
        CredentialsManager.shared.clearSignature()
        CredentialsManager.shared.clearPincodes()
        CredentialsManager.shared.removeDeviceId(for: jid)
        SignatureManager.shared.clear()
        CredentialsManager.shared.clearSignature()
        ApplicationStateManager.shared.clearApplicationBlockedState()
        if AccountDeletionCredentialCleanupPolicy.shouldClearSharedKeychain(
            supportsMultiaccounts: CommonConfigManager.shared.config.supports_multiaccounts
        ) {
            CredentialsManager.shared.clearKeyachain()
        }
        
        self.updateConnectingUsers { value in
            value.remove(jid)
        }
        
        CommonContactsMetadataManager.shared.clear(for: jid)
    }

    private func performStorageAccountDeletionCleanup(jid: String) throws {
        let realm = try WRealm.safe()
        try autoreleasepool {
            try realm.write {
                AccountDeletionStorageCleanupStep.defaultSteps.forEach { step in
                    step.perform(jid)
                }
            }
        }
    }

    private func performPostRealmAccountDeletionCleanup(jid: String) {
        removeAccountFromMemory(jid: jid)
        if let index = ApplicationStateManager.shared.expiredTokenAccountsList.firstIndex(where: { $0.jid == jid }) {
            ApplicationStateManager.shared.expiredTokenAccountsList.remove(at: index)
        }
    }

    private func removeAccountFromMemory(jid: String) {
        autoreleasepool { () -> Void in
            _ = userStorage.removeFirst(where: { $0.jid == jid })
        }
    }

    private func finishAccountDeletion(
        _ result: AccountDeletionCleanupResult,
        diagnosticsSession: AccountDeletionDiagnosticsSessionBox
    ) {
        if result.succeeded {
            diagnosticsSession.finish()
            return
        }

        if let failedStage = result.failedStage {
            diagnosticsSession.fail(stage: failedStage)
        }
        DDLogDebug("AccountManager: deleteAccount failed for \(result.jid) at \(result.failedStage?.rawValue ?? "unknown")")
//        ApplicationStateManager.shared.expiredTokenAccountsList.remove(jid)
    }
    
    func changeNewUserState(for jid: String, to state: UserObserver.State) {
        guard newAccountJid.isNotEmpty,
              jid == newAccountJid else {
            if newAccountJid.isNotEmpty || state.isTerminalSignInState {
                ConnectionDiagnosticsLogger.log(
                    event: "account_manager_new_user_state_ignored",
                    stream: .primary,
                    jid: jid,
                    details: [
                        "state": state.diagnosticName,
                        "activeNewAccountJid": newAccountJid.isEmpty ? "none" : newAccountJid
                    ]
                )
            }
            return
        }

        newAccountObservable.accept(UserObserver(jid: jid, state: state))
        if state.isTerminalSignInState {
            newAccountJid = ""
        }
    }
    
    final func markAsConnected(jid: String) {
        ConnectionDiagnosticsLogger.log(
            event: "account_manager_mark_connected_requested",
            stream: .primary,
            jid: jid,
            details: [
                "connectingContains": self.connectingUsers.value.contains(jid),
                "connectingCount": self.connectingUsers.value.count,
                "authenticatedContains": self.authenticatedUsers.value.contains(jid),
                "authenticatedCount": self.authenticatedUsers.value.count
            ]
        )
        self.updateConnectingUsers { value in
            let wasPresent = value.contains(jid)
            value.remove(jid)
            ConnectionDiagnosticsLogger.log(
                event: "account_manager_mark_connected",
                stream: .primary,
                jid: jid,
                details: [
                    "set": "connectingUsers",
                    "wasPresent": wasPresent,
                    "isPresent": value.contains(jid),
                    "count": value.count
                ]
            )
        }
    }

    final func markAsNotConnecting(
        jid: String,
        reason: String,
        clearAuthentication: Bool = false
    ) {
        ConnectionDiagnosticsLogger.log(
            event: "account_manager_mark_not_connecting_requested",
            stream: .primary,
            jid: jid,
            details: [
                "reason": reason,
                "clearAuthentication": clearAuthentication,
                "connectingContains": self.connectingUsers.value.contains(jid),
                "connectingCount": self.connectingUsers.value.count,
                "authenticatedContains": self.authenticatedUsers.value.contains(jid),
                "authenticatedCount": self.authenticatedUsers.value.count
            ]
        )
        self.updateConnectingUsers { value in
            let wasPresent = value.contains(jid)
            value.remove(jid)
            ConnectionDiagnosticsLogger.log(
                event: "account_manager_mark_not_connecting",
                stream: .primary,
                jid: jid,
                details: [
                    "set": "connectingUsers",
                    "reason": reason,
                    "wasPresent": wasPresent,
                    "isPresent": value.contains(jid),
                    "count": value.count
                ]
            )
        }
        guard clearAuthentication else { return }
        self.updateAuthenticatedUsers { value in
            let wasPresent = value.contains(jid)
            value.remove(jid)
            ConnectionDiagnosticsLogger.log(
                event: "account_manager_mark_not_connecting",
                stream: .primary,
                jid: jid,
                details: [
                    "set": "authenticatedUsers",
                    "reason": reason,
                    "wasPresent": wasPresent,
                    "isPresent": value.contains(jid),
                    "count": value.count
                ]
            )
        }
    }
    
    final func markAsAuthencticated(jid: String) {
        ConnectionDiagnosticsLogger.log(
            event: "account_manager_mark_authenticated_requested",
            stream: .primary,
            jid: jid,
            details: [
                "connectingContains": self.connectingUsers.value.contains(jid),
                "connectingCount": self.connectingUsers.value.count,
                "authenticatedContains": self.authenticatedUsers.value.contains(jid),
                "authenticatedCount": self.authenticatedUsers.value.count
            ]
        )
        self.updateAuthenticatedUsers { value in
            let wasPresent = value.contains(jid)
            value.remove(jid)
            ConnectionDiagnosticsLogger.log(
                event: "account_manager_mark_authenticated",
                stream: .primary,
                jid: jid,
                details: [
                    "set": "authenticatedUsers",
                    "wasPresent": wasPresent,
                    "isPresent": value.contains(jid),
                    "count": value.count
                ]
            )
        }
    }
    
    final func markAsConnecting(jid: String) {
        ConnectionDiagnosticsLogger.log(
            event: "account_manager_mark_connecting_requested",
            stream: .primary,
            jid: jid,
            details: [
                "connectingContains": self.connectingUsers.value.contains(jid),
                "connectingCount": self.connectingUsers.value.count,
                "authenticatedContains": self.authenticatedUsers.value.contains(jid),
                "authenticatedCount": self.authenticatedUsers.value.count
            ]
        )
        self.updateConnectingUsers { value in
            let wasPresent = value.contains(jid)
            value.insert(jid)
            ConnectionDiagnosticsLogger.log(
                event: "account_manager_mark_connecting",
                stream: .primary,
                jid: jid,
                details: [
                    "set": "connectingUsers",
                    "wasPresent": wasPresent,
                    "isPresent": value.contains(jid),
                    "count": value.count
                ]
            )
        }
        self.updateAuthenticatedUsers { value in
            let wasPresent = value.contains(jid)
            value.insert(jid)
            ConnectionDiagnosticsLogger.log(
                event: "account_manager_mark_connecting",
                stream: .primary,
                jid: jid,
                details: [
                    "set": "authenticatedUsers",
                    "wasPresent": wasPresent,
                    "isPresent": value.contains(jid),
                    "count": value.count
                ]
            )
        }
    }
    
    final func prepareForForeground() {
        self.users.forEach {
            $0.connectionResilience.setForegroundActive(true)
        }
        load()
    }
    
    final func prepareForBackground() {
        self.users.forEach {
            $0.connectionResilience.setForegroundActive(false)
        }
        NotifyManager.shared.clearAllNotifications()
        NotifyManager.shared.setLastChats(displayed: false)
    }
    
    public final func tokenCounterIsIncorrect(jid: String) {
        
    }
    
    public final func tokenRevoked(jid: String) {
        
    }
}
