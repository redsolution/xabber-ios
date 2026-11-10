import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

final class AccountInteractiveArchivePriorityTests: XCTestCase {
    private final class AuthenticatedStream: XMPPStream {
        override var isAuthenticated: Bool { true }
        override var isConnected: Bool { true }
        override func send(_ element: DDXMLElement) {}
    }

    private struct EmptyResolver: ArchiveMessageMaterializationResolving {
        func materializedMessages(conversation: ArchiveConversationKey,
                                  archiveIDs: [String]) async throws -> [ArchiveMaterializedMessageIdentity] { [] }
    }

    private final class ResultState: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private var failure: Error?
        func finish(_ error: Error?) { lock.lock(); completed = true; failure = error; lock.unlock() }
        var isCompleted: Bool { lock.lock(); defer { lock.unlock() }; return completed }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    }

    func testVisibleArchiveStartsWhileBackgroundArchiveIsStillRunning() {
        let scheduler = AccountXMPPTaskScheduler(configuration: .production)
        let backgroundStarted = expectation(description: "background archive started")
        let visibleStarted = expectation(description: "visible archive overtakes background archive")
        let lock = NSLock()
        var releaseBackground: (() -> Void)?

        scheduler.enqueue(priority: .background, resource: .mamArchive,
                          deduplicationKey: "background") { finish in
            lock.lock(); releaseBackground = finish; lock.unlock()
            backgroundStarted.fulfill()
        }
        wait(for: [backgroundStarted], timeout: 1)

        scheduler.enqueue(priority: .interactive, resource: .mamArchive,
                          deduplicationKey: "visible") { finish in
            visibleStarted.fulfill()
            finish()
        }
        let result = XCTWaiter.wait(for: [visibleStarted], timeout: 0.5)
        lock.lock(); let finish = releaseBackground; lock.unlock()
        finish?()
        scheduler.reset()
        XCTAssertEqual(result, .completed,
                       "Opening a visible chat must not wait for an unrelated background archive")
    }

    func testVisibleArchiveBypassesBackgroundCooldown() {
        let scheduler = AccountXMPPTaskScheduler(
            configuration: .test(cooldowns: [.mamArchive: 2]))
        let backgroundFinished = expectation(description: "background finished")
        let visibleStarted = expectation(description: "visible archive bypasses cooldown")
        scheduler.enqueue(priority: .background, resource: .mamArchive,
                          deduplicationKey: "background") { finish in
            finish()
            backgroundFinished.fulfill()
        }
        wait(for: [backgroundFinished], timeout: 1)

        scheduler.enqueue(priority: .interactive, resource: .mamArchive,
                          deduplicationKey: "visible") { finish in
            visibleStarted.fulfill()
            finish()
        }
        let result = XCTWaiter.wait(for: [visibleStarted], timeout: 0.5)
        scheduler.reset()
        XCTAssertEqual(result, .completed,
                       "A background throttle must not delay a user opening a chat")
    }

    func testInteractiveReservationRemainsBoundedWhileBackgroundWorkRuns() {
        let scheduler = AccountXMPPTaskScheduler(configuration: .production)
        let backgroundStarted = expectation(description: "background owns ordinary capacity")
        let firstVisibleStarted = expectation(description: "first visible request owns reservation")
        let secondVisibleStarted = expectation(description: "second visible request starts after release")
        let startedTooEarly = expectation(description: "reservation never admits two visible requests")
        startedTooEarly.isInverted = true
        let lock = NSLock()
        var finishBackground: (() -> Void)?
        var finishFirstVisible: (() -> Void)?
        var checkingEarlyStart = true

        scheduler.enqueue(priority: .background, resource: .mamArchive,
                          deduplicationKey: "held-background") { finish in
            lock.lock(); finishBackground = finish; lock.unlock()
            backgroundStarted.fulfill()
        }
        wait(for: [backgroundStarted], timeout: 1)
        scheduler.enqueue(priority: .interactive, resource: .mamArchive,
                          deduplicationKey: "first-visible") { finish in
            lock.lock(); finishFirstVisible = finish; lock.unlock()
            firstVisibleStarted.fulfill()
        }
        wait(for: [firstVisibleStarted], timeout: 1)
        scheduler.enqueue(priority: .interactive, resource: .mamArchive,
                          deduplicationKey: "second-visible") { finish in
            lock.lock(); let tooEarly = checkingEarlyStart; lock.unlock()
            if tooEarly { startedTooEarly.fulfill() }
            secondVisibleStarted.fulfill()
            finish()
        }
        wait(for: [startedTooEarly], timeout: 0.1)
        lock.lock()
        checkingEarlyStart = false
        let releaseVisible = finishFirstVisible
        lock.unlock()
        releaseVisible?()
        wait(for: [secondVisibleStarted], timeout: 1)
        scheduler.reset()
        lock.lock(); let releaseBackground = finishBackground; lock.unlock()
        releaseBackground?()
    }

    func testForegroundArchiveStillWaitsForOccupiedBackgroundCapacity() {
        let scheduler = AccountXMPPTaskScheduler(configuration: .production)
        let backgroundStarted = expectation(description: "background started")
        let foregroundStarted = expectation(description: "ordinary foreground remains bounded")
        foregroundStarted.isInverted = true
        let lock = NSLock()
        var releaseBackground: (() -> Void)?
        scheduler.enqueue(priority: .background, resource: .mamArchive,
                          deduplicationKey: "background") { finish in
            lock.lock(); releaseBackground = finish; lock.unlock()
            backgroundStarted.fulfill()
        }
        wait(for: [backgroundStarted], timeout: 1)
        scheduler.enqueue(priority: .foreground, resource: .mamArchive,
                          deduplicationKey: "ordinary") { finish in
            foregroundStarted.fulfill()
            finish()
        }
        wait(for: [foregroundStarted], timeout: 0.1)
        scheduler.reset()
        lock.lock(); let finish = releaseBackground; lock.unlock()
        finish?()
    }

    func testRawFinalReleasesWireLaneWhileArchivePersistenceIsStillHeld() throws {
        let previous = Realm.Configuration.defaultConfiguration
        let owner = "archive-priority-\(UUID().uuidString)@example.invalid"
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: owner)
        let retainedRealm = try Realm()
        MessageArchiveEndPageDispatcher.resetForTests()
        MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
        MessageArchiveRequestFailureDispatcher.resetForTests()
        defer {
            _ = retainedRealm
            Realm.Configuration.defaultConfiguration = previous
            MessageArchiveEndPageDispatcher.resetForTests()
            MessageArchiveRequestFailurePreparationDispatcher.resetForTests()
            MessageArchiveRequestFailureDispatcher.resetForTests()
        }
        let account = Account(jid: owner, queue: DispatchQueue(label: owner))
        let stream = AuthenticatedStream()
        stream.myJID = XMPPJID(string: owner, resource: "priority-test")
        account.xmppStream = stream
        account.sendReadiness.markStreamManagementEnabled()
        let adapter = MessageArchiveTransportAdapter(account: account,
            materializationResolver: EmptyResolver(), requestTerminalTimeout: 5,
            persistenceTerminalTimeout: 5)
        let query = "wire-lane-\(UUID().uuidString)"
        let request = ArchiveTransportRequest(queryID: query,
            conversation: ArchiveConversationKey(owner: owner, jid: "peer@example.invalid", conversationType: .regular),
            locator: .latest, connectionGeneration: 1, pageSize: 80,
            contextBefore: 0, contextAfter: 0, proofFingerprint: "test-session",
            isUnfiltered: true, producesContinuousCoverage: true, usesFlippedPage: true)
        let terminal = expectation(description: "archive remains protected by persistence barrier")
        let result = ResultState()
        Task {
            do {
                _ = try await adapter.request(request, priority: .visibleIntegrity)
                result.finish(nil)
            } catch { result.finish(error) }
            terminal.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !account.mam.callbackQueueContains(where: { $0.elementId == query }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(account.mam.callbackQueueContains { $0.elementId == query })
        let held = expectation(description: "message persistence held")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        account.messages.queue.async {
            held.fulfill()
            _ = release.wait(timeout: .now() + 4)
        }
        wait(for: [held], timeout: 1)
        let final = try XMPPIQ(xmlString: "<iq type='result' id='\(query)'><fin xmlns='urn:xmpp:mam:2' complete='true' queryid='\(query)'><set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set></fin></iq>")
        XCTAssertTrue(account.mam.read(stream, withIQ: final))
        let nextWireWork = expectation(description: "next wire work does not wait for storage")
        account.xmppTaskScheduler.enqueue(priority: .background, resource: .mamArchive,
                                         deduplicationKey: "next-wire") { finish in
            nextWireWork.fulfill()
            finish()
        }
        let wireResult = XCTWaiter.wait(for: [nextWireWork], timeout: 0.8)
        XCTAssertEqual(wireResult, .completed)
        XCTAssertFalse(result.isCompleted, "Releasing a wire lane must not bypass the archive persistence barrier")
        release.signal()
        wait(for: [terminal], timeout: 3)
        XCTAssertNil(result.error)
        account.xmppTaskScheduler.reset()
    }
}
