import XCTest
@testable import xabber

final class AccountTokenHTTPBootstrapTests: XCTestCase {
    private final class AccountManagerSpy: XabberAccountManager {
        var cachedToken: String?
        var requestStarts = true
        private(set) var requestedAccounts: [String] = []

        override func token(for account: String, now: TimeInterval) -> String? {
            cachedToken
        }

        override func requestToken(
            for account: String,
            callback: ((String?) -> Void)? = nil
        ) -> Bool {
            requestedAccounts.append(account)
            return requestStarts
        }
    }

    func testMissingUsableTokenStartsHTTPAuthenticationForSelectedAccount() {
        let manager = AccountManagerSpy()
        let account = "alice@example.test"

        let started = manager.requestTokenIfNeeded(for: account)

        XCTAssertTrue(started)
        XCTAssertEqual(manager.requestedAccounts, [account])
    }

    func testValidCachedTokenDoesNotStartAnotherAuthentication() {
        let manager = AccountManagerSpy()
        manager.cachedToken = "valid-account-token"

        let started = manager.requestTokenIfNeeded(for: "alice@example.test")

        XCTAssertFalse(started)
        XCTAssertTrue(manager.requestedAccounts.isEmpty)
    }

    func testSettingsWithoutAnAccountDoesNotStartAuthentication() {
        let manager = AccountManagerSpy()

        let started = manager.requestTokenIfNeeded(for: "")

        XCTAssertFalse(started)
        XCTAssertTrue(manager.requestedAccounts.isEmpty)
    }

    func testUnavailableAccountReportsThatAuthenticationDidNotStart() {
        let manager = AccountManagerSpy()
        manager.requestStarts = false

        let started = manager.requestTokenIfNeeded(for: "offline@example.test")

        XCTAssertFalse(started)
        XCTAssertEqual(manager.requestedAccounts, ["offline@example.test"])
    }
}
