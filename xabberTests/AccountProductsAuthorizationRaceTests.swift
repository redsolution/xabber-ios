import XCTest
@testable import xabber

final class AccountProductsAuthorizationRaceTests: XCTestCase {

    func testEarlyConfirmationIsMatchedWhenHTTPRegistrationArrivesLater() {
        let store = XabberAccountManager.TokenCorrelationStore()
        let confirmation = XabberAccountManager.TokenConfirmation(
            requestId: "early-request",
            code: "one-time-code",
            account: "alice@example.test"
        )

        guard case .buffered = store.receive(confirmation) else {
            return XCTFail("Expected the early confirmation to be buffered")
        }

        let task = XabberAccountManager.AuthTaskItem(
            requestId: confirmation.requestId,
            account: confirmation.account
        )
        guard case .matched(let matchedConfirmation) = store.register(task) else {
            return XCTFail("Expected late HTTP registration to match the buffered confirmation")
        }

        XCTAssertEqual(matchedConfirmation, confirmation)
        XCTAssertNil(store.timeoutTask(requestId: confirmation.requestId))
    }

    func testNormalRegistrationThenConfirmationStillMatchesExactlyOnce() {
        let store = XabberAccountManager.TokenCorrelationStore()
        let task = XabberAccountManager.AuthTaskItem(
            requestId: "normal-request",
            account: "alice@example.test"
        )
        let confirmation = XabberAccountManager.TokenConfirmation(
            requestId: task.requestId,
            code: "one-time-code",
            account: task.account
        )

        guard case .waiting = store.register(task) else {
            return XCTFail("Expected task registration to wait for XMPP confirmation")
        }
        guard case .matched(let matchedTask) = store.receive(confirmation) else {
            return XCTFail("Expected XMPP confirmation to match the registered task")
        }

        XCTAssertTrue(matchedTask === task)
        guard case .duplicate = store.receive(confirmation) else {
            return XCTFail("Duplicate confirmation must not start a second token exchange")
        }
    }

    func testLateConfirmationAfterTimeoutIsIgnored() {
        let store = XabberAccountManager.TokenCorrelationStore()
        let task = XabberAccountManager.AuthTaskItem(
            requestId: "timed-out-request",
            account: "alice@example.test"
        )
        let confirmation = XabberAccountManager.TokenConfirmation(
            requestId: task.requestId,
            code: "late-code",
            account: task.account
        )

        guard case .waiting = store.register(task) else {
            return XCTFail("Expected task registration to wait")
        }

        XCTAssertTrue(store.timeoutTask(requestId: task.requestId) === task)
        guard case .duplicate = store.receive(confirmation) else {
            return XCTFail("A timed-out request must stay terminal")
        }
    }

    func testConfirmationForDifferentAccountCannotCompleteTask() {
        let store = XabberAccountManager.TokenCorrelationStore()
        let task = XabberAccountManager.AuthTaskItem(
            requestId: "account-bound-request",
            account: "alice@example.test"
        )
        let confirmation = XabberAccountManager.TokenConfirmation(
            requestId: task.requestId,
            code: "wrong-account-code",
            account: "bob@example.test"
        )

        guard case .waiting = store.register(task) else {
            return XCTFail("Expected task registration to wait")
        }
        guard case .accountMismatch(let mismatchedTask) = store.receive(confirmation) else {
            return XCTFail("Confirmation must be bound to the requesting account")
        }

        XCTAssertTrue(mismatchedTask === task)
        XCTAssertNil(store.timeoutTask(requestId: task.requestId))
    }

    func testAccountConfirmationURLDoesNotClaimGalleryConfirmation() {
        let accountAPIBaseURL = "https://api.example.test/"

        XCTAssertTrue(
            XabberAccountManager.isAccountTokenConfirmationURL(
                "https://api.example.test/xmpp_auth/code_request/confirm",
                accountAPIBaseURL: accountAPIBaseURL
            )
        )
        XCTAssertFalse(
            XabberAccountManager.isAccountTokenConfirmationURL(
                "https://gallery.example.test/api/xmpp_auth/code_request/confirm",
                accountAPIBaseURL: accountAPIBaseURL
            )
        )
    }

    func testAccountProductsRetryUsesFreshAccountAPIBearerHeaderAfter401() {
        var authorizationHeaders: [String] = []
        var requestCount = 0
        let executor = AccountProductsAuthenticatedRequestExecutor(
            tokenProvider: { "stale-account-api-token" },
            clearStoredToken: {},
            requestFreshToken: { completion in
                completion("fresh-account-api-token")
                return true
            },
            request: { token, completion in
                let headers = SubscribtionsManager.accountProductsHTTPHeaders(
                    accountAPIToken: token
                )
                authorizationHeaders.append(headers["Authorization"] ?? "")
                requestCount += 1
                completion(
                    .success(
                        statusCode: requestCount == 1 ? 401 : 200,
                        value: [:]
                    )
                )
            }
        )

        executor.execute { _ in }

        XCTAssertEqual(
            authorizationHeaders,
            [
                "Bearer stale-account-api-token",
                "Bearer fresh-account-api-token"
            ]
        )
    }

}
