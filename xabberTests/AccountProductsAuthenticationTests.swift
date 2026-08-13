import XCTest
@testable import xabber

final class AccountProductsAuthenticationTests: XCTestCase {
    private var accountsToClean: [String] = []

    override func tearDown() {
        accountsToClean.forEach { account in
            CredentialsManager.shared.removeXabberAccountToken(for: account)
            CredentialsManager.shared.removeXabberAccountTokenExpire(for: account)
        }
        accountsToClean.removeAll()
        super.tearDown()
    }

    func testExpiredStoredTokenIsRejectedAndRemovedWithItsExpiry() {
        let account = makeAccount()
        CredentialsManager.shared.setXabberAccountToken(for: account, token: "expired-token")
        CredentialsManager.shared.setXabberAccountTokenExpire(for: account, expire: 999)

        let token = XabberAccountManager.shared.token(for: account, now: 1_000)

        XCTAssertNil(token)
        XCTAssertNil(CredentialsManager.getXabberAccountToken(for: account))
        XCTAssertNil(CredentialsManager.getXabberAccountTokenExpire(for: account))
    }

    func testLegacyStoredTokenWithoutExpiryRemainsUsable() {
        let account = makeAccount()
        CredentialsManager.shared.setXabberAccountToken(for: account, token: "legacy-token")
        CredentialsManager.shared.removeXabberAccountTokenExpire(for: account)

        let token = XabberAccountManager.shared.token(for: account, now: 1_000)

        XCTAssertEqual(token, "legacy-token")
        XCTAssertEqual(CredentialsManager.getXabberAccountToken(for: account), "legacy-token")
        XCTAssertNil(CredentialsManager.getXabberAccountTokenExpire(for: account))
    }

    func testFutureStoredTokenRemainsUsable() {
        let account = makeAccount()
        CredentialsManager.shared.setXabberAccountToken(for: account, token: "current-token")
        CredentialsManager.shared.setXabberAccountTokenExpire(for: account, expire: 1_001)

        let token = XabberAccountManager.shared.token(for: account, now: 1_000)

        XCTAssertEqual(token, "current-token")
        XCTAssertEqual(CredentialsManager.getXabberAccountTokenExpire(for: account), 1_001)
    }

    func testUnauthorizedResponseClearsCredentialsRenewsAndRetriesExactlyOnce() {
        var requestedTokens: [String] = []
        var clearCount = 0
        var renewalCount = 0
        var completionCount = 0
        var finalStatusCode: Int?
        let executor = AccountProductsAuthenticatedRequestExecutor(
            tokenProvider: { "stale-token" },
            clearStoredToken: { clearCount += 1 },
            requestFreshToken: { completion in
                renewalCount += 1
                completion("fresh-token")
                return true
            },
            request: { token, completion in
                requestedTokens.append(token)
                completion(.success(statusCode: token == "stale-token" ? 401 : 200, value: [:]))
            }
        )

        executor.execute { result in
            completionCount += 1
            if case .response(let response) = result {
                finalStatusCode = response.statusCode
            }
        }

        XCTAssertEqual(requestedTokens, ["stale-token", "fresh-token"])
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(renewalCount, 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(finalStatusCode, 200)
    }

    func testForbiddenResponseUsesTheSameSingleRenewalPath() {
        var requestedTokens: [String] = []
        var clearCount = 0
        var renewalCount = 0
        let executor = AccountProductsAuthenticatedRequestExecutor(
            tokenProvider: { "forbidden-token" },
            clearStoredToken: { clearCount += 1 },
            requestFreshToken: { completion in
                renewalCount += 1
                completion("replacement-token")
                return true
            },
            request: { token, completion in
                requestedTokens.append(token)
                completion(.success(statusCode: token == "forbidden-token" ? 403 : 204, value: [:]))
            }
        )

        executor.execute { _ in }

        XCTAssertEqual(requestedTokens, ["forbidden-token", "replacement-token"])
        XCTAssertEqual(clearCount, 1)
        XCTAssertEqual(renewalCount, 1)
    }

    func testSecondAuthorizationFailureDoesNotRenewOrRetryAgain() {
        var requestCount = 0
        var clearCount = 0
        var renewalCount = 0
        var completionCount = 0
        var finalStatusCode: Int?
        let executor = AccountProductsAuthenticatedRequestExecutor(
            tokenProvider: { "stale-token" },
            clearStoredToken: { clearCount += 1 },
            requestFreshToken: { completion in
                renewalCount += 1
                completion("still-invalid-token")
                return true
            },
            request: { _, completion in
                requestCount += 1
                completion(.success(statusCode: requestCount == 1 ? 401 : 403, value: [:]))
            }
        )

        executor.execute { result in
            completionCount += 1
            if case .response(let response) = result {
                finalStatusCode = response.statusCode
            }
        }

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(clearCount, 2)
        XCTAssertEqual(renewalCount, 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(finalStatusCode, 403)
    }

    func testDuplicateDependencyCallbacksStillCompleteOnlyOnce() {
        var requestCount = 0
        var renewalCount = 0
        var completionCount = 0
        let executor = AccountProductsAuthenticatedRequestExecutor(
            tokenProvider: { "stale-token" },
            clearStoredToken: {},
            requestFreshToken: { completion in
                renewalCount += 1
                completion("fresh-token")
                completion("duplicate-token")
                return true
            },
            request: { token, completion in
                requestCount += 1
                if token == "stale-token" {
                    completion(.success(statusCode: 401, value: [:]))
                    completion(.success(statusCode: 200, value: [:]))
                } else {
                    completion(.success(statusCode: 200, value: [:]))
                    completion(.success(statusCode: 200, value: [:]))
                }
            }
        )

        executor.execute { _ in completionCount += 1 }

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(renewalCount, 1)
        XCTAssertEqual(completionCount, 1)
    }

    func testMissingTokenCanBeAcquiredWithoutConsumingAuthorizationRetry() {
        var suppliedToken: String?
        var renewalCount = 0
        var requestCount = 0
        let executor = AccountProductsAuthenticatedRequestExecutor(
            tokenProvider: { nil },
            clearStoredToken: {},
            requestFreshToken: { completion in
                renewalCount += 1
                let token = renewalCount == 1 ? "initial-token" : "retried-token"
                suppliedToken = token
                completion(token)
                return true
            },
            request: { token, completion in
                requestCount += 1
                if token == "initial-token" {
                    completion(.success(statusCode: 401, value: [:]))
                } else {
                    completion(.success(statusCode: 200, value: [:]))
                }
            }
        )

        executor.execute { _ in }

        XCTAssertEqual(suppliedToken, "retried-token")
        XCTAssertEqual(renewalCount, 2)
        XCTAssertEqual(requestCount, 2)
    }

    func testRefreshGenerationRejectsOlderResponseForSameAccount() {
        let tracker = AccountProductsRefreshGenerationTracker()
        let first = tracker.begin(for: "alice@example.test")
        let second = tracker.begin(for: "alice@example.test")

        XCTAssertFalse(tracker.isCurrent(for: "alice@example.test", generation: first))
        XCTAssertTrue(tracker.isCurrent(for: "alice@example.test", generation: second))
    }

    func testRefreshGenerationIsIsolatedPerAccount() {
        let tracker = AccountProductsRefreshGenerationTracker()
        let alice = tracker.begin(for: "alice@example.test")
        let bob = tracker.begin(for: "bob@example.test")
        _ = tracker.begin(for: "alice@example.test")

        XCTAssertFalse(tracker.isCurrent(for: "alice@example.test", generation: alice))
        XCTAssertTrue(tracker.isCurrent(for: "bob@example.test", generation: bob))
    }

    private func makeAccount() -> String {
        let account = "account-products-auth-\(UUID().uuidString)@example.test"
        accountsToClean.append(account)
        return account
    }
}
