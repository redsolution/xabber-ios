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
                "outcome=error " +
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
}
