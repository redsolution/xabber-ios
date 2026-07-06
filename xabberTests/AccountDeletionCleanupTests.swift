import XCTest
@testable import xabber

final class AccountDeletionCleanupTests: XCTestCase {
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
