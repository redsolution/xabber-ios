import XCTest
import RealmSwift
@testable import xabber

final class PasscodeWipeCoordinatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("passcode-wipe-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testBeginPersistsMarkerBeforeDeletingAnyAccountData() throws {
        let marker = PasscodeWipeMarkerStore(
            markerURL: directory.appendingPathComponent("wipe-pending-v1")
        )
        var observedPendingDuringCleanup = false
        let transaction = PasscodeWipeTransaction(marker: marker) {
            observedPendingDuringCleanup = try marker.readPending()
        }

        try transaction.begin()

        XCTAssertTrue(observedPendingDuringCleanup)
        XCTAssertFalse(try marker.readPending())
    }

    func testFailedCleanupRemainsPendingAndResumesAfterNewTransaction() throws {
        let markerURL = directory.appendingPathComponent("wipe-pending-v1")
        let firstMarker = PasscodeWipeMarkerStore(markerURL: markerURL)
        let first = PasscodeWipeTransaction(marker: firstMarker) {
            throw TestError.storageUnavailable
        }

        XCTAssertThrowsError(try first.begin())
        XCTAssertTrue(try firstMarker.readPending())

        var resumed = false
        let restartedMarker = PasscodeWipeMarkerStore(markerURL: markerURL)
        let restarted = PasscodeWipeTransaction(marker: restartedMarker) {
            resumed = true
        }
        try restarted.resumeIfNeeded()

        XCTAssertTrue(resumed)
        XCTAssertFalse(try restartedMarker.readPending())
    }

    func testMarkerWriteFailureDoesNotStartDeletion() throws {
        let occupiedParent = directory.appendingPathComponent("occupied")
        try Data("file".utf8).write(to: occupiedParent)
        let marker = PasscodeWipeMarkerStore(
            markerURL: occupiedParent.appendingPathComponent("wipe-pending-v1")
        )
        var cleanupWasCalled = false
        let transaction = PasscodeWipeTransaction(marker: marker) {
            cleanupWasCalled = true
        }

        XCTAssertThrowsError(try transaction.begin())
        XCTAssertFalse(cleanupWasCalled)
        XCTAssertTrue(marker.isPendingOrUnavailable)
    }

    func testCorruptMarkerFailsClosedAndDoesNotRunCleanup() throws {
        let markerURL = directory.appendingPathComponent("wipe-pending-v1")
        try Data("unexpected".utf8).write(to: markerURL)
        let marker = PasscodeWipeMarkerStore(markerURL: markerURL)
        var cleanupWasCalled = false
        let transaction = PasscodeWipeTransaction(marker: marker) {
            cleanupWasCalled = true
        }

        XCTAssertTrue(marker.isPendingOrUnavailable)
        XCTAssertThrowsError(try transaction.resumeIfNeeded())
        XCTAssertFalse(cleanupWasCalled)
    }

    func testRealmCleanupIncludesEnabledAndDisabledAccounts() throws {
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "passcode-wipe-\(UUID().uuidString)"
        )
        let realm = try Realm(configuration: configuration)
        let enabled = AccountStorageItem()
        enabled.jid = "enabled@example.com"
        enabled.enabled = true
        let disabled = AccountStorageItem()
        disabled.jid = "disabled@example.com"
        disabled.enabled = false
        let disabledAccountQuota = AccountQuotaStorageItem()
        disabledAccountQuota.primary = "disabled@example.com|quota"
        disabledAccountQuota.jid = "disabled@example.com"
        try realm.write {
            realm.add([enabled, disabled])
            realm.add(disabledAccountQuota)
        }
        XCTAssertEqual(realm.objects(AccountStorageItem.self).count, 2)
        XCTAssertEqual(realm.objects(AccountQuotaStorageItem.self).count, 1)

        try PasscodeWipeRealmCleaner.clear(configuration: configuration)

        XCTAssertTrue(realm.objects(AccountStorageItem.self).isEmpty)
        XCTAssertTrue(realm.objects(AccountQuotaStorageItem.self).isEmpty)
    }

    func testClosedDiskRealmFilesAreRemovedBeforeMarkerClears() throws {
        let realmURL = directory.appendingPathComponent("account-data.realm")
        let configuration = Realm.Configuration(fileURL: realmURL)
        try autoreleasepool {
            let realm = try Realm(configuration: configuration)
            let account = AccountStorageItem()
            account.jid = "stale@example.com"
            try realm.write { realm.add(account) }
        }
        let managementURL = URL(fileURLWithPath: realmURL.path + ".management", isDirectory: true)
        // Realm owns the `.note` sidecar; on this runtime it is a FIFO, so
        // writing test bytes to it would block the test process indefinitely.
        try FileManager.default.createDirectory(at: managementURL, withIntermediateDirectories: true)
        try Data("stale-attachment".utf8).write(
            to: managementURL.appendingPathComponent("stale-file")
        )
        let marker = PasscodeWipeMarkerStore(
            markerURL: directory.appendingPathComponent("wipe-pending-v1")
        )
        let transaction = PasscodeWipeTransaction(marker: marker) {
            XCTAssertTrue(try marker.readPending())
            try PasscodeWipeRealmCleaner.clear(configuration: configuration)
        }

        try transaction.begin()

        XCTAssertFalse(try marker.readPending())
        for file in PasscodeWipeRealmCleaner.diskFileURLs(configuration: configuration) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
        }
    }

    func testPushStartedBeforeWipeStaysNeutralAfterMarkerClears() throws {
        let marker = PasscodeWipeMarkerStore(
            markerURL: directory.appendingPathComponent("wipe-pending-v1")
        )
        let requestGeneration = try marker.readGeneration()
        XCTAssertFalse(marker.shouldNeutralizeRequest(startGeneration: requestGeneration))

        try marker.markPending()
        XCTAssertTrue(marker.shouldNeutralizeRequest(startGeneration: requestGeneration))
        let generationWhilePending = try marker.readGeneration()
        XCTAssertNotEqual(requestGeneration, generationWhilePending)

        try marker.clearPending()
        let generationAfterWipe = try marker.readGeneration()
        XCTAssertNotEqual(requestGeneration, generationAfterWipe)
        XCTAssertNotEqual(generationWhilePending, generationAfterWipe)
        XCTAssertTrue(marker.shouldNeutralizeRequest(startGeneration: requestGeneration))
        XCTAssertTrue(marker.shouldNeutralizeRequest(
            startGeneration: generationAfterWipe,
            startedPending: true
        ))
        XCTAssertFalse(marker.shouldNeutralizeRequest(startGeneration: generationAfterWipe))
    }

    private enum TestError: Error {
        case storageUnavailable
    }
}
