import XCTest
@testable import xabber

final class SubscriptionDiagnosticsTests: XCTestCase {

    func testMessageRendersStableStructuredPurchaseFields() throws {
        let attemptID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))

        let message = SubscriptionDiagnosticEvent.message(
            event: .storeKitResult,
            attemptID: attemptID,
            source: .purchase,
            productID: "com_xabber_premium_account.monthly",
            outcome: .pending,
            reason: .awaitingApproval,
            accountBinding: .attached,
            expirationState: .missing,
            entitlementActive: false,
            persisted: false
        )

        XCTAssertEqual(
            message,
            "SUBSCRIPTION_DIAGNOSTICS event=storekit_result " +
                "attempt=00000000-0000-0000-0000-000000000123 " +
                "source=purchase " +
                "product_id=\"com_xabber_premium_account.monthly\" " +
                "outcome=pending " +
                "reason=awaiting_approval " +
                "account_binding=attached " +
                "expiration_state=missing " +
                "entitlement_active=false persisted=false"
        )
    }

    func testMessageEscapesStoreKitErrorDescription() throws {
        let attemptID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000456"))
        let error = NSError(
            domain: "SKErrorDomain",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Payment failed\nAsk \"Apple\""]
        )

        let message = SubscriptionDiagnosticEvent.message(
            event: .storeKitError,
            attemptID: attemptID,
            source: .purchase,
            productID: "com_xabber_premium_account.yearly",
            outcome: .error,
            error: error
        )

        XCTAssertEqual(
            message,
            "SUBSCRIPTION_DIAGNOSTICS event=storekit_error " +
                "attempt=00000000-0000-0000-0000-000000000456 " +
                "source=purchase " +
                "product_id=\"com_xabber_premium_account.yearly\" " +
                "outcome=error error_category=storekit " +
                "error_domain=\"SKErrorDomain\" error_code=2 " +
                "error_description=\"Payment failed\\nAsk \\\"Apple\\\"\""
        )
    }

    func testMessageSchemaDoesNotExposeAccountOrTransactionSecrets() throws {
        let attemptID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000789"))

        let message = SubscriptionDiagnosticEvent.message(
            event: .transactionEvaluated,
            attemptID: attemptID,
            source: .transactionUpdates,
            productID: "com_xabber_premium_account.monthly",
            outcome: .rejected,
            reason: .unknownAccountBinding,
            accountBinding: .unresolved,
            expirationState: .active,
            entitlementActive: false,
            persisted: false
        )

        [
            "jid=",
            "app_account_token=",
            "transaction_id=",
            "original_transaction_id=",
            "receipt=",
            "receipt_data=",
            "token=",
            "authorization="
        ].forEach { forbiddenField in
            XCTAssertFalse(message.contains(forbiddenField), "Unexpected sensitive field: \(forbiddenField)")
        }
    }

    func testMessagesKeepPreviouslySilentStoreKitOutcomesDistinct() throws {
        let attemptID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000999"))
        let productID = "com_xabber_premium_account.monthly"

        let cancelled = SubscriptionDiagnosticEvent.message(
            event: .storeKitResult,
            attemptID: attemptID,
            source: .purchase,
            productID: productID,
            outcome: .userCancelled
        )
        let pending = SubscriptionDiagnosticEvent.message(
            event: .storeKitResult,
            attemptID: attemptID,
            source: .purchase,
            productID: productID,
            outcome: .pending,
            reason: .awaitingApproval
        )
        let unverified = SubscriptionDiagnosticEvent.message(
            event: .storeKitResult,
            attemptID: attemptID,
            source: .purchase,
            productID: productID,
            outcome: .unverified,
            reason: .verificationFailed
        )

        XCTAssertTrue(cancelled.contains("outcome=user_cancelled"))
        XCTAssertTrue(pending.contains("outcome=pending reason=awaiting_approval"))
        XCTAssertTrue(unverified.contains("outcome=unverified reason=verification_failed"))
        XCTAssertEqual(Set([cancelled, pending, unverified]).count, 3)
    }

    func testMessageRendersCorrelatedStoreKitLifecycleContext() throws {
        let attemptID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000001111"))

        let message = SubscriptionDiagnosticEvent.message(
            event: .storeKitFlowLifecycle,
            attemptID: attemptID,
            source: .purchase,
            productID: "com_xabber_premium_account.monthly",
            lifecycle: .willResignActive,
            applicationState: .inactive,
            sceneState: .foregroundInactive,
            storeEnvironment: .sandbox,
            canMakePayments: true,
            elapsedMilliseconds: 725
        )

        XCTAssertEqual(
            message,
            "SUBSCRIPTION_DIAGNOSTICS event=storekit_flow_lifecycle " +
                "attempt=00000000-0000-0000-0000-000000001111 " +
                "source=purchase " +
                "product_id=\"com_xabber_premium_account.monthly\" " +
                "lifecycle=will_resign_active " +
                "application_state=inactive " +
                "scene_state=foreground_inactive " +
                "store_environment=sandbox " +
                "can_make_payments=true elapsed_ms=725"
        )
    }

    func testMessageRendersBackendRequestBoundaryWithoutCredentialValue() throws {
        let attemptID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002222"))

        let message = SubscriptionDiagnosticEvent.message(
            event: .accountProductsRequestStarted,
            attemptID: attemptID,
            source: .purchase,
            productID: "com_xabber_premium_account.monthly",
            outcome: .started,
            endpoint: "https://api.dxs.xabber.com/api/v1/accounts/account-products/",
            requestOrdinal: 1,
            authorizationAttached: true
        )

        XCTAssertEqual(
            message,
            "SUBSCRIPTION_DIAGNOSTICS event=account_products_request_started " +
                "attempt=00000000-0000-0000-0000-000000002222 " +
                "source=purchase " +
                "product_id=\"com_xabber_premium_account.monthly\" " +
                "outcome=started " +
                "endpoint=\"https://api.dxs.xabber.com/api/v1/accounts/account-products/\" " +
                "request_ordinal=1 authorization_attached=true"
        )
        XCTAssertFalse(message.contains("Bearer"))
        XCTAssertFalse(message.contains("token="))
    }

    func testBackendDiagnosticEndpointKeepsConfiguredRouteButRemovesCredentialsAndQuery() {
        XCTAssertEqual(
            SubscribtionsManager.subscriptionDiagnosticEndpoint(
                "https://user:secret@api.dxs.xabber.com/api/v1/accounts/account-products/?token=raw#fragment"
            ),
            "https://api.dxs.xabber.com/api/v1/accounts/account-products/"
        )
    }

    func testMessageRendersBoundedUnderlyingErrorClassification() throws {
        let attemptID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000003333"))
        let underlying = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "No connection"]
        )
        let error = NSError(
            domain: "SKErrorDomain",
            code: 0,
            userInfo: [
                NSLocalizedDescriptionKey: String(repeating: "A", count: 600),
                NSUnderlyingErrorKey: underlying
            ]
        )

        let message = SubscriptionDiagnosticEvent.message(
            event: .storeKitError,
            attemptID: attemptID,
            source: .purchase,
            productID: "com_xabber_premium_account.monthly",
            outcome: .error,
            error: error
        )

        XCTAssertTrue(message.contains("error_category=storekit"))
        XCTAssertTrue(message.contains("underlying_error_1_domain=\"NSURLErrorDomain\""))
        XCTAssertTrue(message.contains("underlying_error_1_code=-1009"))
        XCTAssertFalse(message.contains(String(repeating: "A", count: 241)))
        XCTAssertFalse(message.contains("underlying_error_2_"))
    }
}
