import XCTest
import RealmSwift
@testable import xabber

final class AccountDeletionCoordinatorTests: XCTestCase {
    @MainActor
    func testAccountPresenceRefreshesBackgroundDeletionBeforeChoosingLogoutRoot() throws {
        let previousConfiguration = Realm.Configuration.defaultConfiguration
        let configuration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "AccountDeletionPresence-\(UUID().uuidString)"
        )
        Realm.Configuration.defaultConfiguration = configuration
        let realm = try Realm(configuration: configuration)
        let previousAutorefresh = realm.autorefresh
        realm.autorefresh = false
        defer {
            realm.autorefresh = previousAutorefresh
            Realm.Configuration.defaultConfiguration = previousConfiguration
        }

        let account = AccountStorageItem()
        account.jid = "cleanup@example.test"
        try realm.write { realm.add(account) }
        XCTAssertEqual(AccountManager.shared.accountStorePresence(), .hasAccounts)

        // Keep the main run loop stopped until after the storage commit so its
        // normal Realm notification delivery cannot advance this snapshot.
        let storageFinished = DispatchSemaphore(value: 0)
        DispatchQueue(label: "AccountDeletionCoordinatorTests.presence").async {
            do {
                try autoreleasepool {
                    let storageRealm = try Realm(configuration: configuration)
                    try storageRealm.write {
                        storageRealm.delete(storageRealm.objects(AccountStorageItem.self))
                    }
                }
            } catch {
                XCTFail("Background account deletion failed: \(error)")
            }
            storageFinished.signal()
        }
        XCTAssertEqual(storageFinished.wait(timeout: .now() + 2), .success)

        XCTAssertEqual(realm.objects(AccountStorageItem.self).count, 1,
                       "The main-thread snapshot has not advanced to the deletion commit")
        XCTAssertEqual(AccountManager.shared.accountStorePresence(), .empty,
                       "Logout must choose its root from committed storage, not a stale main-thread snapshot")
    }

    func testCleanupStagesRunInExpectedOrder() {
        let completionExpectation = expectation(description: "cleanup completes")
        let recorder = ThreadSafeCleanupStageRecorder()
        let coordinator = AccountDeletionCleanupCoordinator(
            storageQueue: { work in
                DispatchQueue(label: "AccountDeletionCoordinatorTests.storage").async(execute: work)
            },
            completionQueue: { work in
                DispatchQueue.main.async(execute: work)
            }
        )

        coordinator.runAsync(
            jid: "cleanup@example.test",
            hard: true,
            operations: AccountDeletionCleanupOperations(
                preRealmCleanup: {
                    recorder.append("pre")
                },
                storageCleanup: {
                    recorder.append("storage")
                },
                postCleanup: {
                    recorder.append("post")
                }
            )
        ) { result in
            recorder.append("completion")
            XCTAssertTrue(result.succeeded)
            XCTAssertNil(result.failedStage)
            XCTAssertEqual(recorder.values, ["pre", "storage", "post", "completion"])
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 2)
    }

    func testStorageCleanupRunsOffMainThread() {
        let completionExpectation = expectation(description: "cleanup completes")
        let coordinator = AccountDeletionCleanupCoordinator(
            storageQueue: { work in
                DispatchQueue(label: "AccountDeletionCoordinatorTests.storage").async(execute: work)
            },
            completionQueue: { work in
                DispatchQueue.main.async(execute: work)
            }
        )

        coordinator.runAsync(
            jid: "cleanup@example.test",
            hard: true,
            operations: AccountDeletionCleanupOperations(
                preRealmCleanup: {},
                storageCleanup: {},
                postCleanup: {}
            )
        ) { result in
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(result.storageInvokedOnMainThread, false)
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 2)
    }

    func testStorageFailureProducesDeterministicResultAndSkipsPostStage() {
        let completionExpectation = expectation(description: "cleanup completes")
        let recorder = ThreadSafeCleanupStageRecorder()
        let coordinator = AccountDeletionCleanupCoordinator(
            storageQueue: { work in
                DispatchQueue(label: "AccountDeletionCoordinatorTests.storage").async(execute: work)
            },
            completionQueue: { work in
                DispatchQueue.main.async(execute: work)
            }
        )

        coordinator.runAsync(
            jid: "cleanup@example.test",
            hard: true,
            operations: AccountDeletionCleanupOperations(
                preRealmCleanup: {
                    recorder.append("pre")
                },
                storageCleanup: {
                    recorder.append("storage")
                    throw CleanupFailure.storage
                },
                postCleanup: {
                    recorder.append("post")
                }
            )
        ) { result in
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.failedStage, .storageCleanup)
            XCTAssertEqual(result.errorDescription, "storage failed")
            XCTAssertEqual(recorder.values, ["pre", "storage"])
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation], timeout: 2)
    }

    func testPreCleanupFailureDoesNotStartStorageDeletion() throws {
        var stages: [String] = []
        var results: [AccountDeletionCleanupResult] = []
        let coordinator = AccountDeletionCleanupCoordinator(
            storageQueue: { $0() },
            completionQueue: { $0() }
        )

        coordinator.runAsync(
            jid: "cleanup@example.test",
            hard: true,
            operations: AccountDeletionCleanupOperations(
                preRealmCleanup: {
                    stages.append("pre")
                    throw CleanupFailure.pre
                },
                storageCleanup: { stages.append("storage") },
                postCleanup: { stages.append("post") }
            )
        ) { results.append($0) }

        XCTAssertEqual(stages, ["pre"])
        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failedStage, .preRealmCleanup)
        XCTAssertNil(result.storageInvokedOnMainThread)
    }

    func testPostCleanupFailureDoesNotReportSuccessfulDeletion() throws {
        var stages: [String] = []
        var results: [AccountDeletionCleanupResult] = []
        let coordinator = AccountDeletionCleanupCoordinator(
            storageQueue: { $0() },
            completionQueue: { $0() }
        )

        coordinator.runAsync(
            jid: "cleanup@example.test",
            hard: true,
            operations: AccountDeletionCleanupOperations(
                preRealmCleanup: { stages.append("pre") },
                storageCleanup: { stages.append("storage") },
                postCleanup: {
                    stages.append("post")
                    throw CleanupFailure.post
                }
            )
        ) { results.append($0) }

        XCTAssertEqual(stages, ["pre", "storage", "post"])
        XCTAssertEqual(results.count, 1)
        let result = try XCTUnwrap(results.first)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failedStage, .postCleanup)
        XCTAssertEqual(result.errorDescription, "post cleanup failed")
    }

    func testDefaultStorageCleanupPlanKeepsCurrentCategoriesRepresented() {
        XCTAssertEqual(
            AccountDeletionStorageCleanupKind.defaultOrder,
            [
                .account,
                .vCards,
                .messages,
                .presence,
                .deviceSessionCredentials,
                .groupchats,
                .recentChats,
                .clientSynchronization,
                .blocks,
                .serverDiscovery,
                .roster,
                .messageDeletes,
                .reliableDelivery,
                .omemo,
                .certificates,
                .notifications,
                .favorites,
                .authenticatedKeyExchange,
                .subscriptions,
                .remainingAccountData
            ]
        )
    }
}

private enum CleanupFailure: LocalizedError {
    case pre
    case storage
    case post

    var errorDescription: String? {
        switch self {
        case .pre: return "pre cleanup failed"
        case .storage: return "storage failed"
        case .post: return "post cleanup failed"
        }
    }
}

private final class ThreadSafeCleanupStageRecorder {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
