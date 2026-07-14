import XCTest
@testable import xabber

final class AccountMissingCredentialPolicyTests: XCTestCase {
    func testMissingPasswordRequiresReauthenticationWithoutAuthorizingDeletion() {
        let disposition = AccountAuthenticationSafetyPolicy.disposition(
            for: .missingLocalCredential(kind: .password)
        )

        XCTAssertEqual(disposition, .reauthenticationRequired(kind: .password))
        XCTAssertFalse(disposition.authorizesAccountDeletion)
        XCTAssertEqual(disposition.userMessage, "Sign in again to restore account access. Your local data was kept.")
    }

    func testMissingTokenAndSecretRemainNonDestructive() {
        for kind in [CredentialsManager.Storage.Kind.token, .secret] {
            let disposition = AccountAuthenticationSafetyPolicy.disposition(
                for: .missingLocalCredential(kind: kind)
            )

            XCTAssertEqual(disposition, .reauthenticationRequired(kind: kind))
            XCTAssertFalse(disposition.authorizesAccountDeletion)
        }
    }

    func testLocallyInvalidatedCredentialDoesNotBecomeServerRevocationEvidence() {
        let disposition = AccountAuthenticationSafetyPolicy.disposition(
            for: .locallyInvalidatedCredential(kind: .token)
        )

        XCTAssertEqual(disposition, .reauthenticationRequired(kind: .token))
        XCTAssertFalse(disposition.authorizesAccountDeletion)
    }

    func testStoringReplacementCredentialClearsLocalInvalidationState() {
        let storage = CredentialsManager.Storage(
            jid: "replacement-credential-\(UUID().uuidString)@example.test"
        )
        storage.storeToken("old-token")
        storage.release(.credentialRevoked)
        var invalidatedBeforeReplacement: Bool?
        storage.use { isInvalidated, item in
            invalidatedBeforeReplacement = isInvalidated
            item.release(.authFailedRecoverable)
        }

        storage.storePassword("replacement-password")
        var invalidatedAfterReplacement: Bool?
        storage.use { isInvalidated, _ in
            invalidatedAfterReplacement = isInvalidated
        }

        XCTAssertEqual(invalidatedBeforeReplacement, true)
        XCTAssertEqual(invalidatedAfterReplacement, false)
    }

    func testTransportAndAuthenticationStartFailuresRemainRetryable() {
        XCTAssertEqual(
            AccountAuthenticationSafetyPolicy.disposition(for: .authenticationStartFailed),
            .retryableFailure
        )
        XCTAssertEqual(
            AccountAuthenticationSafetyPolicy.disposition(for: .ambiguousAuthenticationFailure),
            .retryableFailure
        )
    }

    func testCurrentPrimarySASLAccountDisabledCreatesAuthoritativeEvidence() {
        let disposition = AccountAuthenticationSafetyPolicy.disposition(
            for: .saslAccountDisabled(
                source: .primaryAccount,
                isCurrentStream: true,
                eventID: "primary-sasl-account-disabled"
            )
        )

        guard case .authoritativeRevocation(let evidence) = disposition else {
            return XCTFail("Expected authoritative revocation")
        }
        XCTAssertEqual(evidence.source, .currentPrimarySASLAccountDisabled)
        XCTAssertEqual(evidence.eventID, "primary-sasl-account-disabled")
        XCTAssertTrue(disposition.authorizesAccountDeletion)
    }

    func testStaleOrSecondarySASLAccountDisabledCannotDeleteAccount() {
        XCTAssertEqual(
            AccountAuthenticationSafetyPolicy.disposition(
                for: .saslAccountDisabled(
                    source: .primaryAccount,
                    isCurrentStream: false,
                    eventID: "stale"
                )
            ),
            .retryableFailure
        )
        XCTAssertEqual(
            AccountAuthenticationSafetyPolicy.disposition(
                for: .saslAccountDisabled(
                    source: .secondaryStream,
                    isCurrentStream: true,
                    eventID: "secondary"
                )
            ),
            .retryableFailure
        )
    }

    func testMatchingServerHeadlineCreatesAuthoritativeEvidence() {
        let disposition = AccountAuthenticationSafetyPolicy.disposition(
            for: .deviceHeadlineRevocation(
                isServerSender: true,
                isHeadline: true,
                namespaceMatches: true,
                revokedDeviceID: "device-1",
                currentDeviceID: "device-1",
                eventID: "headline-1"
            )
        )

        guard case .authoritativeRevocation(let evidence) = disposition else {
            return XCTFail("Expected authoritative revocation")
        }
        XCTAssertEqual(evidence.source, .verifiedCurrentDeviceHeadline)
        XCTAssertEqual(evidence.eventID, "headline-1")
    }

    func testUntrustedOrMismatchedHeadlineCannotDeleteAccount() {
        let inputs: [AccountAuthenticationSafetyEvent] = [
            .deviceHeadlineRevocation(
                isServerSender: false,
                isHeadline: true,
                namespaceMatches: true,
                revokedDeviceID: "device-1",
                currentDeviceID: "device-1",
                eventID: "not-server"
            ),
            .deviceHeadlineRevocation(
                isServerSender: true,
                isHeadline: false,
                namespaceMatches: true,
                revokedDeviceID: "device-1",
                currentDeviceID: "device-1",
                eventID: "not-headline"
            ),
            .deviceHeadlineRevocation(
                isServerSender: true,
                isHeadline: true,
                namespaceMatches: false,
                revokedDeviceID: "device-1",
                currentDeviceID: "device-1",
                eventID: "wrong-namespace"
            ),
            .deviceHeadlineRevocation(
                isServerSender: true,
                isHeadline: true,
                namespaceMatches: true,
                revokedDeviceID: "device-2",
                currentDeviceID: "device-1",
                eventID: "other-device"
            ),
            .deviceHeadlineRevocation(
                isServerSender: true,
                isHeadline: true,
                namespaceMatches: true,
                revokedDeviceID: nil,
                currentDeviceID: "device-1",
                eventID: "missing-device"
            )
        ]

        for input in inputs {
            let disposition = AccountAuthenticationSafetyPolicy.disposition(for: input)
            XCTAssertEqual(disposition, .retryableFailure)
            XCTAssertFalse(disposition.authorizesAccountDeletion)
        }
    }

    func testTypedRevocationRequestRequiresAuthoritativeEvidence() {
        let evidence = AccountRevocationEvidence(
            source: .currentPrimarySASLAccountDisabled,
            eventID: "account-disabled"
        )
        let request = AccountRevocationRequest(
            jid: "owner@example.test",
            message: "Device was revoked",
            evidence: evidence
        )

        XCTAssertEqual(request.jid, "owner@example.test")
        XCTAssertEqual(request.evidence, evidence)
    }

    func testRawJIDNotificationIsRejectedWithoutTypedEvidence() {
        let notification = Notification(
            name: ApplicationStateManager.tokenWasExpired,
            object: "owner@example.test"
        )

        XCTAssertNil(AccountRevocationNotificationParser.request(from: notification))
    }

    func testTypedRevocationNotificationIsAccepted() {
        let request = AccountRevocationRequest(
            jid: "owner@example.test",
            message: "Device was revoked",
            evidence: AccountRevocationEvidence(
                source: .verifiedCurrentDeviceHeadline,
                eventID: "headline-typed"
            )
        )
        let notification = Notification(
            name: ApplicationStateManager.tokenWasExpired,
            object: request
        )

        XCTAssertEqual(AccountRevocationNotificationParser.request(from: notification), request)
    }

    func testDuplicateAuthoritativeRequestIsClaimedOnlyOnce() {
        let request = AccountRevocationRequest(
            jid: "owner@example.test",
            message: "Device was revoked",
            evidence: AccountRevocationEvidence(
                source: .verifiedCurrentDeviceHeadline,
                eventID: "headline-1"
            )
        )
        let gate = AccountRevocationProcessingGate()

        XCTAssertTrue(gate.claim(request))
        XCTAssertFalse(gate.claim(request))
    }

    func testMissingCredentialDiagnosticsDoNotContainSecretMaterial() {
        let line = AccountAuthenticationSafetyDiagnostic(
            source: .localCredential,
            reason: .missingLocalCredential,
            credentialKind: .password,
            counterReserved: false
        ).line

        XCTAssertTrue(line.contains("source=localCredential"))
        XCTAssertTrue(line.contains("reason=missingLocalCredential"))
        XCTAssertTrue(line.contains("credentialKind=password"))
        XCTAssertTrue(line.contains("counterReserved=false"))
        XCTAssertFalse(line.lowercased().contains("secret="))
        XCTAssertFalse(line.lowercased().contains("token="))
        XCTAssertFalse(line.lowercased().contains("password="))
    }
}
