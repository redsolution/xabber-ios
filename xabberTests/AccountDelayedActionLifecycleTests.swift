import XCTest
@testable import xabber

final class AccountDelayedActionLifecycleTests: XCTestCase {
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
        weak var releasedAccount: Account?

        autoreleasepool {
            var account: Account? = Account(
                jid: "released-delayed-action@example.com",
                queue: DispatchQueue(label: "AccountDelayedActionLifecycleTests.released")
            )
            releasedAccount = account
            account?.delayedAction(delay: 0.05) { _, _ in
                actionDidNotRun.fulfill()
            }
            account = nil
        }

        XCTAssertNil(releasedAccount)
        wait(for: [actionDidNotRun], timeout: 0.15)
    }
}
