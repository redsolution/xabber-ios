import XCTest
import RealmSwift
@testable import xabber

final class AccountDeletionCleanupTests: XCTestCase {
    func testFinalCleanupRemovesRemainingOwnerRowsAndPreservesOtherAccountAndDeviceSettings() throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "AccountDeletionRemaining-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let realm = try WRealm.safe()
        let owner = "removed-\(UUID().uuidString.lowercased())@example.test"
        let otherOwner = "retained-\(UUID().uuidString.lowercased())@example.test"
        let removedRows = remainingRows(owner: owner)
        let retainedRows = remainingRows(owner: otherOwner)
        let deviceSettings = NotifyManagerStorage()
        deviceSettings.showMessageNotify = false
        try realm.write {
            realm.add(removedRows + retainedRows)
            realm.add(deviceSettings)
        }
        let finalStep = try XCTUnwrap(AccountDeletionStorageCleanupStep.defaultSteps.last)

        try realm.write { try finalStep.perform(owner) }

        for row in removedRows {
            XCTAssertTrue(row.isInvalidated, "Final account cleanup must remove \(type(of: row))")
        }
        for row in retainedRows {
            XCTAssertFalse(row.isInvalidated, "Another account's \(type(of: row)) must remain")
            XCTAssertEqual(row.value(forKey: "owner") as? String, otherOwner)
        }
        XCTAssertFalse(deviceSettings.isInvalidated)
        XCTAssertFalse(deviceSettings.showMessageNotify)
    }

    func testMessageCleanupRemovesPrivateAttachmentsTemporaryStanzasAndHistoryForDeletedOwnerOnly() throws {
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "AccountDeletionMessages-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let realm = try WRealm.safe()
        let owner = "removed-\(UUID().uuidString.lowercased())@example.test"
        let otherOwner = "retained-\(UUID().uuidString.lowercased())@example.test"
        let removedRows = messageRows(owner: owner)
        let retainedRows = messageRows(owner: otherOwner)
        try realm.write { realm.add(removedRows + retainedRows) }

        try realm.write {
            for step in AccountDeletionStorageCleanupStep.defaultSteps
            where step.kind == .messages || step.kind == .recentChats {
                try step.perform(owner)
            }
        }

        for row in removedRows {
            XCTAssertTrue(row.isInvalidated, "\(type(of: row)) must be removed with the account")
        }
        for row in retainedRows {
            XCTAssertFalse(row.isInvalidated, "Another account's \(type(of: row)) must remain")
            XCTAssertEqual(row.value(forKey: "owner") as? String, otherOwner)
        }
    }

    func testAccountCleanupRemovesOwnVCardAvatarsAndQuotaWhilePreservingOtherAccount() throws {
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment),
            "Account credential cleanup must use the isolated hosted-test service")
        let previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: "AccountDeletionProfile-\(UUID())")
        defer { Realm.Configuration.defaultConfiguration = previous }
        let realm = try WRealm.safe()
        let owner = "removed-\(UUID().uuidString.lowercased())@example.test"
        let otherOwner = "retained-\(UUID().uuidString.lowercased())@example.test"
        let removedRows = profileRows(owner: owner)
        let retainedRows = profileRows(owner: otherOwner)
        try realm.write { realm.add(removedRows + retainedRows) }

        try realm.write {
            for step in AccountDeletionStorageCleanupStep.defaultSteps
            where step.kind == .account || step.kind == .vCards {
                try step.perform(owner)
            }
        }

        for row in removedRows {
            XCTAssertTrue(row.isInvalidated, "\(type(of: row)) must be removed with the account")
        }
        for row in retainedRows {
            XCTAssertFalse(row.isInvalidated, "Another account's \(type(of: row)) must remain")
        }
        XCTAssertEqual(realm.objects(AccountStorageItem.self).map(\.jid), [otherOwner])
    }

    private func messageRows(owner: String) -> [Object] {
        let rows: [Object] = [
            MessageStorageItem(),
            MessageMediaAttachmentStorageItem(),
            TemporaryMessageStanzaStorageItem(),
            ChatLocalHistoryIndexStorageItem(),
            ConversationArchiveCoverageStorageItem(),
            RegularChatArchiveSyncStateStorageItem()
        ]
        for (index, row) in rows.enumerated() {
            row.setValue("\(owner):\(index)", forKey: "primary")
            row.setValue(owner, forKey: "owner")
        }
        return rows
    }

    private func remainingRows(owner: String) -> [Object] {
        let rows: [Object] = [
            PreaprovedSubscribtionStorageItem(),
            RosterGroupStorageItem(),
            RosterDisplayNameStorageItem(),
            ClientDiscoStorageItem(),
            ShowedNotificationRequests(),
            XMPPMessageScheduleStorageItem(),
            XMPPAbuseConfigStorageItem(),
            XMPPAbuseReportStorageItem(),
            UINotificationStorageItem(),
            NotifyPersonalStorageItem()
        ]
        for (index, row) in rows.enumerated() {
            if row.objectSchema.properties.contains(where: { $0.name == "primary" }) {
                row.setValue("\(owner):\(index)", forKey: "primary")
            }
            row.setValue(owner, forKey: "owner")
        }
        return rows
    }

    private func profileRows(owner: String) -> [Object] {
        let account = AccountStorageItem()
        account.jid = owner
        let profile = vCardStorageItem()
        profile.jid = owner
        profile.owner = owner
        profile.fn = "Private display name"
        let avatar = AvatarStorageItem()
        avatar.primary = AvatarStorageItem.genPrimary(jid: owner, owner: owner)
        avatar.jid = owner
        avatar.owner = owner
        avatar.imageOriginal = "file:///private-avatar.png"
        let quota = AccountQuotaStorageItem()
        quota.primary = AccountQuotaStorageItem.genPrimary(jid: owner)
        quota.jid = owner
        quota.totalBytes = 1234
        return [account, profile, avatar, quota]
    }

    func testDiagnosticsRecordsStartAndFinishForAccountDeletion() {
        var clock = FakeAccountDeletionClock(times: [10, 11, 13, 16])
        var events: [AccountDeletionDiagnosticsEvent] = []
        let recorder = AccountDeletionDiagnosticsRecorder(
            clock: { clock.next() },
            sink: { events.append($0) }
        )

        var session = recorder.begin(
            jid: "delete@example.com",
            hard: true,
            invokedOnMainThread: true
        )
        session.markPreRealmCleanupFinished()
        session.markRealmWriteFinished()
        session.finish()

        XCTAssertEqual(events.map(\.name), [.started, .finished])
        XCTAssertEqual(events.last?.totalDurationMs, 6000)
        XCTAssertEqual(events.last?.preRealmCleanupMs, 1000)
        XCTAssertEqual(events.last?.realmWriteMs, 2000)
        XCTAssertEqual(events.last?.postCleanupMs, 3000)
    }

    func testDiagnosticsRecordMainThreadInvocation() {
        var clock = FakeAccountDeletionClock(times: [1, 2])
        var events: [AccountDeletionDiagnosticsEvent] = []
        let recorder = AccountDeletionDiagnosticsRecorder(
            clock: { clock.next() },
            sink: { events.append($0) }
        )

        var session = recorder.begin(
            jid: "background-delete@example.com",
            hard: true,
            invokedOnMainThread: false
        )
        session.finish()

        XCTAssertEqual(events.first?.name, .started)
        XCTAssertEqual(events.last?.name, .finished)
        XCTAssertEqual(events.first?.invokedOnMainThread, false)
        XCTAssertEqual(events.last?.invokedOnMainThread, false)
    }

    func testDiagnosticsCanUseFakeTimingWithoutLargeRealmDataset() {
        var clock = FakeAccountDeletionClock(times: [100, 100.125, 100.5, 101.25])
        var events: [AccountDeletionDiagnosticsEvent] = []
        let recorder = AccountDeletionDiagnosticsRecorder(
            clock: { clock.next() },
            sink: { events.append($0) }
        )

        var session = recorder.begin(
            jid: "timed-delete@example.com",
            hard: true,
            invokedOnMainThread: true
        )
        session.markPreRealmCleanupFinished()
        session.markRealmWriteFinished()
        session.finish()

        XCTAssertEqual(events.last?.preRealmCleanupMs, 125)
        XCTAssertEqual(events.last?.realmWriteMs, 375)
        XCTAssertEqual(events.last?.postCleanupMs, 750)
        XCTAssertEqual(events.last?.totalDurationMs, 1250)
    }

    func testHardFlagIsPreservedThroughDiagnostics() {
        var clock = FakeAccountDeletionClock(times: [10, 11])
        var events: [AccountDeletionDiagnosticsEvent] = []
        let recorder = AccountDeletionDiagnosticsRecorder(
            clock: { clock.next() },
            sink: { events.append($0) }
        )

        var session = recorder.begin(
            jid: "soft-delete@example.com",
            hard: false,
            invokedOnMainThread: true
        )
        session.finish()

        XCTAssertEqual(events.map(\.hard), [false, false])
    }

    func testDiagnosticsRecordFailureStageAndStorageThread() {
        var clock = FakeAccountDeletionClock(times: [1, 2, 5, 6])
        var events: [AccountDeletionDiagnosticsEvent] = []
        let recorder = AccountDeletionDiagnosticsRecorder(
            clock: { clock.next() },
            sink: { events.append($0) }
        )

        var session = recorder.begin(
            jid: "failed-delete@example.com",
            hard: true,
            invokedOnMainThread: true
        )
        session.markPreRealmCleanupFinished()
        session.markRealmWriteFinished(invokedOnMainThread: false)
        session.fail(stage: .storageCleanup)

        XCTAssertEqual(events.map(\.name), [.started, .failed])
        XCTAssertEqual(events.last?.succeeded, false)
        XCTAssertEqual(events.last?.failedStage, .storageCleanup)
        XCTAssertEqual(events.last?.storageInvokedOnMainThread, false)
        XCTAssertEqual(events.last?.preRealmCleanupMs, 1000)
        XCTAssertEqual(events.last?.realmWriteMs, 3000)
    }

    func testHardFalseKeepsSoftClosePolicy() {
        XCTAssertTrue(AccountDeletionUIActionClosePolicy.closeSoftFlag(hard: false))
        XCTAssertFalse(AccountDeletionUIActionClosePolicy.closeSoftFlag(hard: true))
    }

    func testMultiAccountCredentialClearingPolicyIsPreserved() {
        XCTAssertFalse(
            AccountDeletionCredentialCleanupPolicy.shouldClearSharedKeychain(
                supportsMultiaccounts: true
            )
        )
        XCTAssertTrue(
            AccountDeletionCredentialCleanupPolicy.shouldClearSharedKeychain(
                supportsMultiaccounts: false
            )
        )
    }

    func testApplicationLockSurvivesDeletionWhileStoredAccountRemains() {
        XCTAssertFalse(
            AccountDeletionCredentialCleanupPolicy.shouldClearApplicationLock(
                remainingStoredAccountCount: 1
            )
        )
        XCTAssertTrue(
            AccountDeletionCredentialCleanupPolicy.shouldClearApplicationLock(
                remainingStoredAccountCount: 0
            )
        )
    }

    func testDiagnosticLineDoesNotExposeSecretMaterial() {
        let event = AccountDeletionDiagnosticsEvent(
            name: .finished,
            jid: "safe@example.com",
            hard: true,
            invokedOnMainThread: true,
            totalDurationMs: 10,
            preRealmCleanupMs: 2,
            realmWriteMs: 7,
            postCleanupMs: 1
        )
        let line = event.diagnosticLine()
        let lowercasedLine = line.lowercased()

        XCTAssertTrue(line.contains("event=account_deletion_finished"))
        XCTAssertTrue(line.contains("stream=account-delete"))
        XCTAssertFalse(lowercasedLine.contains("password"))
        XCTAssertFalse(lowercasedLine.contains("credential"))
        XCTAssertFalse(lowercasedLine.contains("privatekey"))
        XCTAssertFalse(lowercasedLine.contains("provisioning"))
    }
}

private struct FakeAccountDeletionClock {
    private var times: [TimeInterval]

    init(times: [TimeInterval]) {
        self.times = times
    }

    mutating func next() -> TimeInterval {
        if times.isEmpty {
            return 0
        }
        return times.removeFirst()
    }
}
