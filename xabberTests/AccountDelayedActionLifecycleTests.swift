import XCTest
@testable import xabber

final class AccountDelayedActionLifecycleTests: XCTestCase {
    private final class DelayedActionLifetimeOwner {}

    func testDelayedActionRunsForLiveAccount() {
        let account = Account(
            jid: "live-delayed-action@example.com",
            queue: DispatchQueue(label: "AccountDelayedActionLifecycleTests.live")
        )
        let actionRan = expectation(description: "delayed action runs")

        account.delayedAction(delay: 0.01) { delayedAccount, stream in
            XCTAssertTrue(delayedAccount === account)
            XCTAssertTrue(stream === account.xmppStream)
            actionRan.fulfill()
        }

        wait(for: [actionRan], timeout: 1)
    }

    func testDelayedActionSkipsDestroyedAccount() {
        let actionDidNotRun = expectation(description: "delayed action is skipped")
        actionDidNotRun.isInverted = true
        weak var releasedOwner: DelayedActionLifetimeOwner?

        autoreleasepool {
            let owner = DelayedActionLifetimeOwner()
            releasedOwner = owner
            AccountDelayedActionScheduler.schedule(
                owner: owner,
                delay: 0.05,
                queueLabel: "AccountDelayedActionLifecycleTests.released"
            ) { _ in
                actionDidNotRun.fulfill()
            }
        }

        XCTAssertNil(
            releasedOwner,
            "the weak-scheduling fixture must not have independent Account lifecycle work"
        )
        wait(for: [actionDidNotRun], timeout: 0.15)
    }
}
