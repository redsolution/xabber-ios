import XCTest
@testable import xabber

final class AccountDeletionCoordinatorTests: XCTestCase {
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
                .subscriptions
            ]
        )
    }
}

private enum CleanupFailure: LocalizedError {
    case storage

    var errorDescription: String? {
        "storage failed"
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
