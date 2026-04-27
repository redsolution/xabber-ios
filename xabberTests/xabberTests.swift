//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import XCTest
import UIKit
import RealmSwift
import XMPPFramework
import MaterialComponents
@testable import xabber

@MainActor
final class InfoScreenHeaderViewTests: XCTestCase {

    private func makeButton(icon: String, title: String) -> InfoHeaderButton {
        let button = InfoHeaderButton()
        button.configure(icon: icon, title: title)
        return button
    }

    private func makeHeader(
        width: CGFloat = 390,
        subtitle: String? = "redsolution.com",
        thirdLine: String? = nil,
        buttons: [UIButton] = []
    ) -> InfoScreenHeaderView {
        let header = InfoScreenHeaderView(frame: .zero)
        header.additionalTopOffset = 56
        header.titleButton.setTitle("Igor Boldin", for: .normal)
        header.titleButton.setTitleColor(.label, for: .normal)

        if !buttons.isEmpty {
            header.configureButtons { buttons }
        } else {
            header.showButtons = false
        }

        header.subtitleLabel.text = subtitle
        header.subtitleLabel.isHidden = subtitle?.isEmpty ?? true

        if let thirdLine {
            header.thirdLineLabel.text = thirdLine
            header.thirdLineLabel.isHidden = false
        } else {
            header.thirdLineLabel.text = nil
            header.thirdLineLabel.isHidden = true
        }

        header.frame = CGRect(x: 0, y: 0, width: width, height: header.preferredHeight)
        header.updateSubviews()
        header.layoutIfNeeded()
        return header
    }

    func testCompactActionButtonsUseTheConfiguredSize() {
        let header = makeHeader(buttons: [
            makeButton(icon: "message.fill", title: "message"),
            makeButton(icon: "phone.fill", title: "call"),
            makeButton(icon: "bell.fill", title: "mute"),
            makeButton(icon: "ellipsis", title: "more"),
        ])

        XCTAssertFalse(header.buttonsStack.isHidden)
        XCTAssertEqual(header.buttons.count, 4)

        for button in header.buttons {
            XCTAssertEqual(button.frame.size.width, 76, accuracy: 0.5)
            XCTAssertEqual(button.frame.size.height, 56, accuracy: 0.5)
        }

        XCTAssertEqual(header.buttonsStack.frame.height, 56, accuracy: 0.5)
    }

    func testSubtitleAndThirdLineSpacingStaysAtEightPoints() {
        let header = makeHeader(thirdLine: "5 members")

        XCTAssertEqual(header.subtitleLabel.frame.minY - header.titleButton.frame.maxY, 8, accuracy: 0.5)
        XCTAssertEqual(header.thirdLineLabel.frame.minY - header.subtitleLabel.frame.maxY, 8, accuracy: 0.5)

        let thirdLineOnlyHeader = makeHeader(subtitle: nil, thirdLine: "5 members")
        XCTAssertEqual(thirdLineOnlyHeader.thirdLineLabel.frame.minY - thirdLineOnlyHeader.titleButton.frame.maxY, 8, accuracy: 0.5)
    }

    func testPreferredHeightGrowsWhenButtonsAreVisible() {
        let headerWithoutButtons = makeHeader()
        let headerWithButtons = makeHeader(buttons: [
            makeButton(icon: "message.fill", title: "message"),
            makeButton(icon: "phone.fill", title: "call"),
            makeButton(icon: "bell.fill", title: "mute"),
            makeButton(icon: "ellipsis", title: "more"),
        ])

        XCTAssertTrue(headerWithoutButtons.buttonsStack.isHidden)
        XCTAssertFalse(headerWithButtons.buttonsStack.isHidden)
        XCTAssertEqual(headerWithButtons.preferredHeight - headerWithoutButtons.preferredHeight, 64, accuracy: 0.5)
    }

    func testEllipsisButtonUsesASymbolImage() {
        let button = makeButton(icon: "ellipsis", title: "more")

        XCTAssertEqual(button.title.text, "more")
        XCTAssertNotNil(button.icon.image)
        XCTAssertTrue(button.icon.image?.isSymbolImage ?? false)
    }
}

private final class TestScheduledTask: VoIPScheduledTask {
    private(set) var cancelCount: Int = 0

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
final class VoIPTerminationReasonTests: XCTestCase {

    func testLegacyStateMappingRespectsDirectionSensitiveReasons() {
        XCTAssertEqual(CallTerminationReason.canceledByCaller.legacyState(outgoing: false), .missed)
        XCTAssertEqual(CallTerminationReason.canceledByCaller.legacyState(outgoing: true), .noanswer)
        XCTAssertEqual(CallTerminationReason.rejectedByCallee.legacyState(outgoing: true), .busy)
        XCTAssertEqual(CallTerminationReason.connectionError.legacyState(outgoing: false), .missed)
        XCTAssertEqual(CallTerminationReason.connectionError.legacyState(outgoing: true), .noanswer)
        XCTAssertEqual(CallTerminationReason.answeredElsewhere.legacyState(outgoing: false), .made)
    }

    func testRejectMessageReasonMappingDistinguishesTimeoutsBusyAndHangup() {
        let manager = VoIPManager()

        XCTAssertEqual(
            manager.terminationReasonFromRejectMessage(
                endReason: MessageStorageItem.VoIPCallState.missed.rawValue,
                callInitiator: "owner@example.com",
                owner: "owner@example.com",
                currentCallDirection: true,
                stanzaDirection: false,
                duration: 0
            ),
            .outgoingUnansweredTimeout
        )
        XCTAssertEqual(
            manager.terminationReasonFromRejectMessage(
                endReason: MessageStorageItem.VoIPCallState.missed.rawValue,
                callInitiator: "peer@example.com",
                owner: "owner@example.com",
                currentCallDirection: false,
                stanzaDirection: true,
                duration: 0
            ),
            .incomingUnansweredTimeout
        )
        XCTAssertEqual(
            manager.terminationReasonFromRejectMessage(
                endReason: MessageStorageItem.VoIPCallState.busy.rawValue,
                callInitiator: "owner@example.com",
                owner: "owner@example.com",
                currentCallDirection: true,
                stanzaDirection: false,
                duration: 0
            ),
            .rejectedByCallee
        )
        XCTAssertEqual(
            manager.terminationReasonFromRejectMessage(
                endReason: MessageStorageItem.VoIPCallState.noanswer.rawValue,
                callInitiator: "owner@example.com",
                owner: "owner@example.com",
                currentCallDirection: true,
                stanzaDirection: true,
                duration: 0
            ),
            .canceledByCaller
        )
        XCTAssertEqual(
            manager.terminationReasonFromRejectMessage(
                endReason: nil,
                callInitiator: "owner@example.com",
                owner: "owner@example.com",
                currentCallDirection: true,
                stanzaDirection: false,
                duration: 12
            ),
            .remoteHangup
        )
        XCTAssertEqual(
            manager.terminationReasonFromRejectMessage(
                endReason: nil,
                callInitiator: "peer@example.com",
                owner: "owner@example.com",
                currentCallDirection: false,
                stanzaDirection: true,
                duration: 12
            ),
            .localHangup
        )
    }

    func testBusyRejectSerializesEndReasonAndInitiator() {
        let call = VoIPCall(
            owner: "owner@example.com",
            fullJid: "peer@example.com/resource",
            callId: "call-id",
            callUUID: UUID(),
            outgoing: false
        )

        call.rejectCall(reason: .busy)
        call.queuedRejectTimeoutWorkItem?.cancel()

        let message = call.stanzaQueue.first as? XMPPMessage
        let reject = message?.element(forName: "reject", xmlns: VoIPCall.namespace)
        let callElement = reject?.element(forName: "call")

        XCTAssertEqual(reject?.attributeStringValue(forName: "id"), "call-id")
        XCTAssertEqual(callElement?.attributeStringValue(forName: "end-reason"), "busy")
        XCTAssertEqual(callElement?.attributeStringValue(forName: "initiator"), "peer@example.com")
    }

    func testCallSessionContextCancelTimersClearsAllScheduledTasks() {
        let context = CallSessionContext(
            callId: "call-id",
            callUUID: UUID(),
            owner: "owner@example.com",
            jid: "peer@example.com/resource",
            outgoing: false,
            phase: .ringing
        )
        let incoming = TestScheduledTask()
        let outgoing = TestScheduledTask()
        let confirmation = TestScheduledTask()
        let media = TestScheduledTask()

        context.incomingTimeoutTask = incoming
        context.outgoingTimeoutTask = outgoing
        context.confirmationTimeoutTask = confirmation
        context.mediaSetupTimeoutTask = media

        context.cancelTimers()

        XCTAssertEqual(incoming.cancelCount, 1)
        XCTAssertEqual(outgoing.cancelCount, 1)
        XCTAssertEqual(confirmation.cancelCount, 1)
        XCTAssertEqual(media.cancelCount, 1)
        XCTAssertNil(context.incomingTimeoutTask)
        XCTAssertNil(context.outgoingTimeoutTask)
        XCTAssertNil(context.confirmationTimeoutTask)
        XCTAssertNil(context.mediaSetupTimeoutTask)
    }
}

final class AccountBootstrapTests: XCTestCase {

    private let testLoginJid = "igor.boldin@xmppdev01.xabber.com"
    private let testLoginPassword = "1234"

    func testAccountUsernameFromJIDHandlesEmptyAndMalformedValues() {
        XCTAssertEqual(Account.username(from: ""), "")
        XCTAssertEqual(Account.username(from: "xmppdev01.xabber.com"), "xmppdev01.xabber.com")
        XCTAssertEqual(Account.username(from: testLoginJid), "igor.boldin")
    }

    func testNotifyManagerExcludedDomainsIgnoresMalformedJIDs() {
        let domains = NotifyManager.excludedDomains(
            from: [
                "",
                "not a jid",
                testLoginJid,
                "room@conference.xabber.com/resource"
            ]
        )

        XCTAssertEqual(domains, [
            "xmppdev01.xabber.com",
            "conference.xabber.com"
        ])
    }

    func testXTokenManagerServerJIDIgnoresMalformedOwners() {
        XCTAssertNil(XTokenManager.serverJID(from: ""))
        XCTAssertNil(XTokenManager.serverJID(from: "not a jid"))
        XCTAssertEqual(XTokenManager.serverJID(from: testLoginJid)?.domain, "xmppdev01.xabber.com")
    }

    func testInjectXMPPCredentials() {
        CredentialsManager.shared.setItem(for: testLoginJid, password: testLoginPassword)

        let stored = CredentialsManager.shared.getItem(for: testLoginJid)
        XCTAssertEqual(stored.kind, .password)
        XCTAssertEqual(stored.creditionalString, testLoginPassword)
    }
}

final class XMPPAuthenticationFailureTests: XCTestCase {

    private func makeFailure(xml: String) throws -> XMPPAuthenticationFailure {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        let element = try XCTUnwrap(document.rootElement())
        return try XCTUnwrap(XMPPAuthenticationFailure(element: element))
    }

    func testParserReadsDocumentedFailureReasonAndText() throws {
        let failure = try makeFailure(xml: """
        <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
          <account-disabled/>
          <text lang="en">Device access revoked</text>
        </failure>
        """)

        XCTAssertEqual(failure.reason, .accountDisabled)
        XCTAssertEqual(failure.text, "Device access revoked")
        XCTAssertTrue(failure.rawXML.contains("account-disabled"))
    }

    func testParserReadsFailureWithoutText() throws {
        let failure = try makeFailure(xml: """
        <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
          <credentials-expired/>
        </failure>
        """)

        XCTAssertEqual(failure.reason, .credentialsExpired)
        XCTAssertNil(failure.text)
    }

    func testParserHandlesMissingCondition() throws {
        let failure = try makeFailure(xml: """
        <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
          <text>Server did not include a condition</text>
        </failure>
        """)

        XCTAssertEqual(failure.reason, .missingCondition)
        XCTAssertEqual(failure.text, "Server did not include a condition")
    }

    func testParserHandlesUnknownCondition() throws {
        let failure = try makeFailure(xml: """
        <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
          <custom-auth-error/>
          <text>Custom auth failure</text>
        </failure>
        """)

        XCTAssertEqual(failure.reason, .unknown("custom-auth-error"))
        XCTAssertEqual(failure.text, "Custom auth failure")
    }

    func testParserCoversStandardSASLFailureConditions() throws {
        let expectations: [(String, XMPPAuthenticationFailureReason)] = [
            ("aborted", .aborted),
            ("account-disabled", .accountDisabled),
            ("credentials-expired", .credentialsExpired),
            ("encryption-required", .encryptionRequired),
            ("incorrect-encoding", .incorrectEncoding),
            ("invalid-authzid", .invalidAuthzid),
            ("invalid-mechanism", .invalidMechanism),
            ("malformed-request", .malformedRequest),
            ("mechanism-too-weak", .mechanismTooWeak),
            ("not-authorized", .notAuthorized),
            ("temporary-auth-failure", .temporaryAuthFailure)
        ]

        for (elementName, expectedReason) in expectations {
            let failure = try makeFailure(xml: """
            <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
              <\(elementName)/>
            </failure>
            """)
            XCTAssertEqual(failure.reason, expectedReason)
        }
    }

    func testResolverRemovesAccountForRevokedDevice() throws {
        let failure = try makeFailure(xml: """
        <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
          <account-disabled/>
          <text>Device access revoked</text>
        </failure>
        """)

        let resolution = XMPPAuthenticationFailureResolution.resolve(
            failure: failure,
            credentialKind: .secret
        )

        XCTAssertEqual(resolution.action, .removeAccount(alertMessage: "Device was revoked"))
        XCTAssertEqual(resolution.statusMessage, "Device was revoked")
        XCTAssertFalse(resolution.shouldLogRawFailure)
    }

    func testResolverDoesNotRemoveAccountForSecondaryRevokedDeviceFailure() throws {
        let failure = try makeFailure(xml: """
        <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
          <account-disabled/>
          <text>Device access revoked</text>
        </failure>
        """)

        let resolution = XMPPAuthenticationFailureResolution.resolve(
            failure: failure,
            credentialKind: .secret,
            source: .secondaryStream
        )

        XCTAssertEqual(resolution.action, .reportGeneric(message: "Device was revoked"))
        XCTAssertEqual(resolution.statusMessage, "Device was revoked")
        XCTAssertTrue(resolution.shouldLogRawFailure)
    }

    func testResolverRefreshesDeviceSecretForExpiredCredentials() throws {
        let failure = try makeFailure(xml: """
        <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
          <credentials-expired/>
        </failure>
        """)

        let resolution = XMPPAuthenticationFailureResolution.resolve(
            failure: failure,
            credentialKind: .secret
        )

        XCTAssertEqual(resolution.action, .refreshDeviceSecret)
        XCTAssertFalse(resolution.shouldLogRawFailure)
    }

    func testResolverRejectsPasswordForNotAuthorizedPasswordAuth() throws {
        let failure = try makeFailure(xml: """
        <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
          <not-authorized/>
        </failure>
        """)

        let resolution = XMPPAuthenticationFailureResolution.resolve(
            failure: failure,
            credentialKind: .password
        )

        XCTAssertEqual(resolution.action, .rejectPassword(message: "Incorrect username or password"))
        XCTAssertEqual(resolution.statusMessage, "Incorrect username or password")
    }

    func testResolverRefreshesDeviceSecretForNotAuthorizedDeviceAuth() throws {
        let failure = try makeFailure(xml: """
        <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
          <not-authorized/>
        </failure>
        """)

        let resolution = XMPPAuthenticationFailureResolution.resolve(
            failure: failure,
            credentialKind: .token
        )

        XCTAssertEqual(resolution.action, .refreshDeviceSecret)
    }

    func testResolverLogsAndReportsGenericFailureForTemporaryAuthFailure() throws {
        let failure = try makeFailure(xml: """
        <failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl">
          <temporary-auth-failure/>
          <text>Try again later</text>
        </failure>
        """)

        let resolution = XMPPAuthenticationFailureResolution.resolve(
            failure: failure,
            credentialKind: .secret
        )

        XCTAssertEqual(resolution.action, .reportGeneric(message: "Try again later"))
        XCTAssertTrue(resolution.shouldLogRawFailure)
    }

    func testCounterTrackerIncrementsOnlyAfterSuccess() {
        let jid = "auth-counter-\(UUID().uuidString)@example.com"
        CredentialsManager.shared.setItem(for: jid, token: "token")
        let storage = CredentialsManager.shared.getItem(for: jid)
        let tracker = XMPPAuthenticationCounterTracker()

        XCTAssertEqual(tracker.counterForAuthentication(using: storage), 1)
        XCTAssertEqual(storage.currentCounter(), 1)

        tracker.authenticationDidSucceed(using: storage)
        XCTAssertEqual(storage.currentCounter(), 2)

        tracker.authenticationDidSucceed(using: storage)
        XCTAssertEqual(storage.currentCounter(), 2)
    }

    func testCounterTrackerDoesNotIncrementAfterFailure() {
        let jid = "auth-counter-failure-\(UUID().uuidString)@example.com"
        CredentialsManager.shared.setItem(for: jid, token: "token")
        let storage = CredentialsManager.shared.getItem(for: jid)
        let tracker = XMPPAuthenticationCounterTracker()

        XCTAssertEqual(tracker.counterForAuthentication(using: storage), 1)
        tracker.authenticationDidFail()

        XCTAssertEqual(storage.currentCounter(), 1)
    }

    func testRecoverableAuthFailureDoesNotInvalidateCredentialStorage() {
        let jid = "recoverable-auth-\(UUID().uuidString)@example.com"
        CredentialsManager.shared.setItem(for: jid, token: "token")
        let storage = CredentialsManager.shared.getItem(for: jid)

        var firstInvalidated: Bool?
        storage.use { isInvalidated, _ in
            firstInvalidated = isInvalidated
        }

        XCTAssertEqual(firstInvalidated, false)

        storage.release(.authFailedRecoverable)

        var secondInvalidated: Bool?
        storage.use { isInvalidated, _ in
            secondInvalidated = isInvalidated
        }

        XCTAssertEqual(secondInvalidated, false)
        storage.release(.authFailedRecoverable)
    }

    func testQueuedUseAfterRecoverableFailureDoesNotReplayStaleCounter() {
        let jid = "recoverable-queue-\(UUID().uuidString)@example.com"
        CredentialsManager.shared.setItem(for: jid, token: "token")
        let storage = CredentialsManager.shared.getItem(for: jid)

        var firstCalled = false
        var queuedCalled = false

        storage.use { _, _ in
            firstCalled = true
        }
        storage.use { _, _ in
            queuedCalled = true
        }

        XCTAssertTrue(firstCalled)
        XCTAssertFalse(queuedCalled)

        storage.release(.authFailedRecoverable)

        XCTAssertFalse(queuedCalled)

        var nextInvalidated: Bool?
        storage.use { isInvalidated, _ in
            nextInvalidated = isInvalidated
        }

        XCTAssertEqual(nextInvalidated, false)
        storage.release(.authFailedRecoverable)
    }

    func testQueuedCredentialUseSerializesCountersAfterSuccess() {
        let jid = "serialized-counter-\(UUID().uuidString)@example.com"
        CredentialsManager.shared.setItem(for: jid, token: "token")
        let storage = CredentialsManager.shared.getItem(for: jid)
        let firstTracker = XMPPAuthenticationCounterTracker()
        let secondTracker = XMPPAuthenticationCounterTracker()

        var firstCounter: UInt64?
        var secondCounter: UInt64?

        storage.use { _, item in
            firstCounter = firstTracker.counterForAuthentication(using: item)
        }
        storage.use { _, item in
            secondCounter = secondTracker.counterForAuthentication(using: item)
        }

        XCTAssertEqual(firstCounter, 1)
        XCTAssertNil(secondCounter)

        firstTracker.authenticationDidSucceed(using: storage)
        storage.release(.authSucceeded)

        XCTAssertEqual(secondCounter, 2)

        secondTracker.authenticationDidFail()
        storage.release(.authFailedRecoverable)
    }

    func testCredentialRevocationKeepsStorageInvalidated() {
        let jid = "credential-revoked-\(UUID().uuidString)@example.com"
        CredentialsManager.shared.setItem(for: jid, token: "token")
        let storage = CredentialsManager.shared.getItem(for: jid)

        storage.use { _, _ in }
        storage.release(.credentialRevoked)
        storage.release(.authFailedRecoverable)

        var invalidated: Bool?
        storage.use { isInvalidated, _ in
            invalidated = isInvalidated
        }

        XCTAssertEqual(invalidated, true)
        storage.release(.authFailedRecoverable)
    }

    func testOCRAHotpFormattingUsesRequestedDigitCount() {
        XCTAssertEqual(DevicesOCRA.hotpString(forTruncatedHash: 123, digits: 8), "00000123")
        XCTAssertEqual(DevicesOCRA.hotpString(forTruncatedHash: 123456789, digits: 4), "6789")
    }
}

final class AccountStreamLifecycleGateTests: XCTestCase {

    func testDuplicateConnectIsSkippedWhileConnecting() {
        let gate = AccountStreamLifecycleGate()

        let first = gate.beginConnect(trigger: .addExistingAccount)
        let second = gate.beginConnect(trigger: .restore)

        guard case .start(let attemptID) = first else {
            XCTFail("Expected first connect to start")
            return
        }

        XCTAssertEqual(second, .skip(phase: .connecting, activeAttemptID: attemptID))
        XCTAssertEqual(gate.snapshot().phase, .connecting)
        XCTAssertEqual(gate.snapshot().activeAttemptID, attemptID)
    }

    func testTimeoutRetryRequiresActiveConnectingAttempt() {
        let gate = AccountStreamLifecycleGate()

        guard case .start(let attemptID) = gate.beginConnect(trigger: .initialLoad) else {
            XCTFail("Expected connect to start")
            return
        }

        XCTAssertTrue(gate.canRetryTimeout(for: attemptID))
        XCTAssertFalse(gate.canRetryTimeout(for: attemptID + 1))

        gate.markAuthenticating()

        XCTAssertFalse(gate.canRetryTimeout(for: attemptID))
    }

    func testPostAuthSetupBlocksNewPrimaryConnect() {
        let gate = AccountStreamLifecycleGate()

        guard case .start(let attemptID) = gate.beginConnect(trigger: .initialLoad) else {
            XCTFail("Expected connect to start")
            return
        }

        gate.markAuthenticating()
        gate.markBinding()
        gate.markPostAuthSetup()

        XCTAssertEqual(
            gate.beginConnect(trigger: .statusUpdate),
            .skip(phase: .postAuthSetup, activeAttemptID: attemptID)
        )
    }

    func testOnlineBlocksRestoreUntilExplicitDisconnect() {
        let gate = AccountStreamLifecycleGate()

        guard case .start = gate.beginConnect(trigger: .initialLoad) else {
            XCTFail("Expected connect to start")
            return
        }

        gate.markAuthenticating()
        gate.markPostAuthSetup()
        gate.markOnline()

        guard case .skip(phase: .online, activeAttemptID: let onlineAttemptID) = gate.beginConnect(trigger: .restore) else {
            XCTFail("Expected online stream to skip restore")
            return
        }

        XCTAssertNotNil(onlineAttemptID)

        gate.markDisconnecting()
        gate.markDisconnected()

        guard case .start(let newAttemptID) = gate.beginConnect(trigger: .restore) else {
            XCTFail("Expected restore after disconnect to start")
            return
        }

        XCTAssertNotEqual(onlineAttemptID, newAttemptID)
    }

    func testDeviceReregisterForceCreatesFreshAttempt() {
        let gate = AccountStreamLifecycleGate()

        guard case .start(let firstAttemptID) = gate.beginConnect(trigger: .initialLoad) else {
            XCTFail("Expected connect to start")
            return
        }

        let forced = gate.beginConnect(trigger: .deviceReregister, force: true)

        guard case .start(let forcedAttemptID) = forced else {
            XCTFail("Expected forced device re-register connect to start")
            return
        }

        XCTAssertNotEqual(firstAttemptID, forcedAttemptID)
        XCTAssertEqual(gate.snapshot().phase, .connecting)
        XCTAssertEqual(gate.snapshot().activeAttemptID, forcedAttemptID)
    }

    func testUIActionStreamConnectsAreSerializedBySameGate() {
        let gate = AccountStreamLifecycleGate()

        guard case .start(let attemptID) = gate.beginConnect(trigger: .uiActionOpen) else {
            XCTFail("Expected UI action stream to start")
            return
        }

        XCTAssertEqual(
            gate.beginConnect(trigger: .uiActionPerformRequest),
            .skip(phase: .connecting, activeAttemptID: attemptID)
        )

        gate.markAuthenticating()
        gate.markOnline()

        XCTAssertEqual(
            gate.beginConnect(trigger: .uiActionRestore),
            .skip(phase: .online, activeAttemptID: attemptID)
        )
    }
}

final class PushNotificationHardeningTests: XCTestCase {

    private func makeIQ(xml: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    func testAPNSPayloadDecoderParsesPlainJSONBody() throws {
        let body = """
        {"action":"regjid","result":"success","jid":"romeo@example.com/resource","node":"node-1","service":"push.example.com"}
        """

        let decoded = try APNSManager.decodeNodeData(from: body)

        XCTAssertEqual(decoded.action, "regjid")
        XCTAssertEqual(decoded.node, "node-1")
        XCTAssertEqual(decoded.service, "push.example.com")
    }

    func testAPNSPayloadDecoderParsesBase64JSONBody() throws {
        let json = """
        {"action":"displayed","encrypted":"payload"}
        """
        let encoded = Data(json.utf8).base64EncodedString()

        let decoded = try APNSManager.decodeNodeData(from: encoded)

        XCTAssertEqual(decoded.action, "displayed")
        XCTAssertEqual(decoded.encrypted, "payload")
    }

    func testAPNSPayloadDecoderRejectsMalformedBody() {
        XCTAssertThrowsError(try APNSManager.decodeNodeData(from: "not-json"))
    }

    func testAPNSRegistrationEligibilityUsesChannelSpecificTokens() {
        let manager = APNSManager.shared
        let previousDeviceToken = manager.deviceToken
        let previousVoIPToken = manager.voipToken

        manager.deviceToken = "device-token"
        manager.voipToken = nil
        XCTAssertTrue(manager.canSendRegistrationRequest(voip: false))
        XCTAssertFalse(manager.canSendRegistrationRequest(voip: true))

        manager.deviceToken = nil
        manager.voipToken = "voip-token"
        XCTAssertFalse(manager.canSendRegistrationRequest(voip: false))
        XCTAssertTrue(manager.canSendRegistrationRequest(voip: true))

        manager.deviceToken = previousDeviceToken
        manager.voipToken = previousVoIPToken
    }

    func testRemoteNotificationProcessingCompletesOnSuccessOnce() {
        var completionResults: [UIBackgroundFetchResult] = []

        let outcome = AppDelegate.processRemoteNotification(
            userInfo: [:],
            voipHandler: { _ in false },
            apnsHandler: { _, completion in
                completion?()
                completion?()
                return .displayed
            },
            cleanupHandler: {},
            fetchCompletionHandler: { completionResults.append($0) }
        )

        XCTAssertEqual(outcome, .push(.displayed))
        XCTAssertEqual(completionResults, [.newData])
    }

    func testRemoteNotificationProcessingCompletesOnInvalidPayload() {
        var completionResults: [UIBackgroundFetchResult] = []

        let outcome = AppDelegate.processRemoteNotification(
            userInfo: [:],
            voipHandler: { _ in false },
            apnsHandler: { _, _ in throw APNSManager.APNSError.invalidPayload },
            cleanupHandler: {},
            fetchCompletionHandler: { completionResults.append($0) }
        )

        XCTAssertEqual(outcome, .noData)
        XCTAssertEqual(completionResults, [.noData])
    }

    func testRemoteNotificationProcessingCleansUpUnknownUserAndCompletes() {
        var didCleanup = false
        var completionResults: [UIBackgroundFetchResult] = []

        let outcome = AppDelegate.processRemoteNotification(
            userInfo: [:],
            voipHandler: { _ in false },
            apnsHandler: { _, _ in throw APNSManager.APNSError.userNotExist },
            cleanupHandler: { didCleanup = true },
            fetchCompletionHandler: { completionResults.append($0) }
        )

        XCTAssertTrue(didCleanup)
        XCTAssertEqual(outcome, .noData)
        XCTAssertEqual(completionResults, [.noData])
    }

    func testPushEnableStaysPendingUntilIQResultArrives() {
        let owner = "romeo@example.com"
        let node = "push-node-\(UUID().uuidString)"
        let manager = PushNotificationsManager(withOwner: owner)
        manager.node = node
        manager.service = "pubsub.example.com"

        let stream = XMPPStream()
        stream.myJID = XMPPJID(string: "\(owner)/ios")

        var callbackResults: [Bool] = []
        manager.enable(xmppStream: stream) { callbackResults.append($0) }

        guard let queryId = manager.queryIds.first else {
            XCTFail("Expected pending query id")
            return
        }

        XCTAssertEqual(manager.enableState, .pending(queryId: queryId))
        XCTAssertTrue(callbackResults.isEmpty)

        CredentialsManager.shared.removePushCredentials(for: node)
    }

    func testPushEnableBecomesEnabledAfterSuccessfulIQResult() throws {
        let owner = "romeo@example.com"
        let node = "push-node-\(UUID().uuidString)"
        let manager = PushNotificationsManager(withOwner: owner)
        manager.node = node
        manager.service = "pubsub.example.com"

        let stream = XMPPStream()
        stream.myJID = XMPPJID(string: "\(owner)/ios")

        var callbackResults: [Bool] = []
        manager.enable(xmppStream: stream) { callbackResults.append($0) }

        guard let queryId = manager.queryIds.first else {
            XCTFail("Expected pending query id")
            return
        }

        let iq = try makeIQ(xml: """
        <iq type='result' id='\(queryId)'>
          <x xmlns='jabber:x:data'>
            <field var='url'><value>https://push.example.com</value></field>
            <field var='jwt'><value>jwt-token</value></field>
          </x>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))
        XCTAssertEqual(manager.enableState, .enabled)
        XCTAssertEqual(callbackResults, [true])
        XCTAssertFalse(manager.queryIds.contains(queryId))

        let credentials = try CredentialsManager.shared.getPushCredentials(for: node)
        XCTAssertEqual(credentials.service, "https://push.example.com")
        XCTAssertEqual(credentials.jwt, "jwt-token")

        CredentialsManager.shared.removePushCredentials(for: node)
    }

    func testPushEnableResetsToDisabledAfterIncompleteIQResult() throws {
        let owner = "romeo@example.com"
        let node = "push-node-\(UUID().uuidString)"
        let manager = PushNotificationsManager(withOwner: owner)
        manager.node = node
        manager.service = "pubsub.example.com"

        let stream = XMPPStream()
        stream.myJID = XMPPJID(string: "\(owner)/ios")

        var callbackResults: [Bool] = []
        manager.enable(xmppStream: stream) { callbackResults.append($0) }

        guard let queryId = manager.queryIds.first else {
            XCTFail("Expected pending query id")
            return
        }

        let iq = try makeIQ(xml: """
        <iq type='result' id='\(queryId)'>
          <x xmlns='jabber:x:data'>
            <field var='url'><value>https://push.example.com</value></field>
          </x>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))
        XCTAssertEqual(manager.enableState, .disabled)
        XCTAssertEqual(callbackResults, [false])
        XCTAssertFalse(manager.queryIds.contains(queryId))

        CredentialsManager.shared.removePushCredentials(for: node)
    }
}

final class NotificationsFeatureTests: XCTestCase {

    private let owner = "igor.boldin@xmppdev01.xabber.com"
    private let notificationsNode = "notifications.xmppdev01.xabber.com"
    private let groupchatJid = "trio@example.com"
    private let groupchatAuthorJid = "romeo@xmppdev01.xabber.com"
    private let currentMemberId = "me-1"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "NotificationsFeatureTests-\(name)")
        AccountManager.shared.users.removeAll { $0.jid == owner }
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        AccountManager.shared.users.removeAll { $0.jid == owner }
        super.tearDown()
    }

    private func makeMessage(xml: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "NotificationsFeatureTests", code: 1)
        }
        return XMPPMessage(from: root)
    }

    private func makeIQ(xml: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "NotificationsFeatureTests", code: 2)
        }
        return XMPPIQ(from: root)
    }

    private func makeAccount() -> Account {
        AccountManager.shared.users.removeAll { $0.jid == owner }
        let account = Account(jid: owner, queue: .main)
        AccountManager.shared.users.append(account)
        return account
    }

    private func upsertNotificationManagerStorage(
        node: String,
        archiveSyncCompleted: Bool = false,
        lastSyncedNotificationId: String? = nil,
        lastItemId: String? = nil,
        unread: Int = 0,
        unreadAfterId: String? = nil
    ) throws {
        let realm = try WRealm.safe()
        let storage = XMPPNotificationsManagerStorageItem()
        storage.owner = owner
        storage.primary = XMPPNotificationsManagerStorageItem.genPrimary(owner: owner)
        storage.node = node
        storage.archiveSyncCompleted = archiveSyncCompleted
        storage.lastSyncedNotificationId = lastSyncedNotificationId
        storage.lastItemId = lastItemId
        storage.unread = unread
        storage.unreadAfterId = unreadAfterId

        try realm.write {
            realm.add(storage, update: .modified)
        }
    }

    @discardableResult
    private func insertNotification(
        jid: String = "security@xmppdev01.xabber.com",
        uniqueId: String,
        stanzaId: String?,
        date: String
    ) throws -> NotificationStorageItem {
        let realm = try WRealm.safe()
        let notification = NotificationStorageItem()
        notification.primary = NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: uniqueId)
        notification.owner = owner
        notification.jid = jid
        notification.uniqueId = uniqueId
        notification.messageId = uniqueId
        notification.stanzaId = stanzaId ?? ""
        notification.category = .info
        notification.shouldShow = true
        notification.date = ISO8601DateFormatter().date(from: date)!

        try realm.write {
            realm.add(notification, update: .modified)
        }

        return notification
    }

    private func queuedNotificationRequest(on account: Account) -> MessageArchiveManager.CallbackQueueItem? {
        account.mam.callbacksQueue.first(where: { $0.task.conversationType == .notifications })
    }

    private func waitForQueuedNotificationRequest(
        on account: Account,
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> MessageArchiveManager.CallbackQueueItem {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let queued = queuedNotificationRequest(on: account) {
                return queued
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        XCTFail("Expected queued notification archive request", file: file, line: line)
        return account.mam.callbacksQueue.first!
    }

    private func sendArchiveFin(
        on account: Account,
        queryId: String,
        complete: Bool,
        count: Int,
        first: String,
        last: String
    ) throws {
        let iq = try makeIQ(xml: """
        <iq type='result' id='\(queryId)'>
          <fin xmlns='urn:xmpp:mam:2' complete='\(complete ? "true" : "false")' queryid='\(queryId)'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>\(count)</count>
              <first>\(first)</first>
              <last>\(last)</last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(account.mam.read(account.xmppStream, withIQ: iq))
    }

    private func managerStorage() throws -> XMPPNotificationsManagerStorageItem? {
        try WRealm.safe().object(ofType: XMPPNotificationsManagerStorageItem.self, forPrimaryKey: XMPPNotificationsManagerStorageItem.genPrimary(owner: owner))
    }

    private func makeArchivedInfoNotificationMessage(
        wrapperId: String,
        stanzaId: String,
        date: String = "2026-03-24T10:15:30Z"
    ) throws -> XMPPMessage {
        try makeMessage(xml: """
        <message type='chat' from='\(owner)' to='\(owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='notifications-query' id='\(stanzaId)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='\(notificationsNode)' to='\(owner)' id='\(wrapperId)'>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='\(stanzaId)'/>
                <notification xmlns='urn:xabber:xen:0' type='alert'>
                  <info>Security update</info>
                </notification>
                <body>Security update</body>
                <addresses xmlns='http://jabber.org/protocol/address'>
                  <address type='ofrom' jid='security@xmppdev01.xabber.com'/>
                </addresses>
                <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='\(date)'/>
              </message>
              <delay xmlns='urn:xmpp:delay' from='xmppdev01.xabber.com' stamp='\(date)'/>
            </forwarded>
          </result>
        </message>
        """)
    }

    private func makeArchivedInfoNotificationMessageWithoutStanzaId(
        wrapperId: String,
        archivedId: String,
        date: String = "2026-03-24T10:15:30Z"
    ) throws -> XMPPMessage {
        try makeMessage(xml: """
        <message type='chat' from='\(owner)' to='\(owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='notifications-query' id='\(archivedId)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='\(notificationsNode)' to='\(owner)' id='\(wrapperId)'>
                <archived xmlns='urn:xmpp:mam:tmp' by='\(owner)' id='\(archivedId)'/>
                <notification xmlns='urn:xabber:xen:0' type='alert'>
                  <info>Security update</info>
                </notification>
                <body>Security update</body>
                <addresses xmlns='http://jabber.org/protocol/address'>
                  <address type='ofrom' jid='security@xmppdev01.xabber.com'/>
                </addresses>
                <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='\(date)'/>
              </message>
              <delay xmlns='urn:xmpp:delay' from='xmppdev01.xabber.com' stamp='\(date)'/>
            </forwarded>
          </result>
        </message>
        """)
    }

    private func insertGroupchatContext() throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = groupchatJid
        chat.conversationType = .group
        chat.primary = LastChatsStorageItem.genPrimary(jid: groupchatJid, owner: owner, conversationType: .group)
        chat.groupchatMyId = currentMemberId

        try realm.write {
            realm.add(chat, update: .modified)
        }
    }

    private func insertGroupchatMemberContext(userId: String? = nil) throws {
        let realm = try WRealm.safe()
        let member = GroupchatUserStorageItem()
        member.owner = owner
        member.userId = userId ?? currentMemberId
        member.jid = owner
        member.groupchatId = [groupchatJid, owner].prp()
        member.primary = GroupchatUserStorageItem.genPrimary(id: member.userId, groupchat: groupchatJid, owner: owner)
        member.isMe = true
        member.isHidden = false

        try realm.write {
            realm.add(member, update: .modified)
        }
    }

    private func makeMentionNotificationMessage(
        wrapperId: String,
        wrapperDate: String = "2026-03-24T11:00:00Z",
        sourceArchivedId: String = "archived-1",
        sourceMessageId: String = "origin-1",
        sourceDate: String = "2026-03-24T10:59:00Z"
    ) throws -> XMPPMessage {
        try makeMessage(xml: """
        <message type='chat' from='notifications.xmppdev01.xabber.com' to='\(owner)' id='\(wrapperId)'>
          <notification xmlns='urn:xabber:xen:0' type='mention'>
            <mention>You were mentioned</mention>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='groupchat' from='\(groupchatJid)' to='\(owner)' id='\(sourceMessageId)'>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(groupchatJid)' id='\(sourceArchivedId)'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='\(sourceMessageId)'/>
                <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='\(sourceDate)'/>
                <body>Hello @you</body>
                <reference xmlns='https://xabber.com/protocol/references' type='groupchat'>
                  <user xmlns='https://xabber.com/protocol/groups' id='author-1'>
                    <nickname>Romeo</nickname>
                  </user>
                </reference>
                <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='6' end='10'>
                  <mention xmlns='https://xabber.com/protocol/markup' node='https://xabber.com/protocol/groupchat'>xmpp:\(groupchatJid)?id=\(currentMemberId)</mention>
                </reference>
              </message>
            </forwarded>
          </notification>
          <body>Fallback mention text</body>
          <addresses xmlns='http://jabber.org/protocol/address'>
            <address type='ofrom' jid='\(groupchatAuthorJid)'/>
          </addresses>
          <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='\(wrapperDate)'/>
        </message>
        """)
    }

    private func makeArchivedCategoryMentionNotificationMessage(
        wrapperId: String = "15934908185152064402",
        wrapperArchivedId: String = "1774446425469615",
        wrapperDate: String = "2026-03-25T13:47:05.469615Z",
        sourceArchivedId: String = "1774446425449434",
        sourceMessageId: String = "dc27b589374e6db3",
        sourceDate: String = "2026-03-25T13:47:05.449434Z"
    ) throws -> XMPPMessage {
        try makeMessage(xml: """
        <message xmlns='jabber:client' to='\(owner)/ios-resource' from='\(owner)'>
          <result id='\(wrapperArchivedId)' queryid='mam-mention-sample' xmlns='urn:xmpp:mam:2'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message to='\(owner)' from='\(notificationsNode)' type='chat' id='\(wrapperId)' xmlns='jabber:client'>
                <archived by='\(owner)' id='\(wrapperArchivedId)' xmlns='urn:xmpp:mam:tmp'/>
                <stanza-id by='\(owner)' id='\(wrapperArchivedId)' xmlns='urn:xmpp:sid:0'/>
                <time by='\(owner)' stamp='\(wrapperDate)' xmlns='https://xabber.com/protocol/delivery'/>
                <notification xmlns='urn:xabber:xen:0' category='mention'>
                  <forwarded xmlns='urn:xmpp:forward:0'>
                    <message xmlns='jabber:client' xml:lang='en' to='\(owner)' from='\(groupchatJid)' type='chat' id='\(sourceMessageId)'>
                      <archived xmlns='urn:xmpp:mam:tmp' by='\(groupchatJid)' id='\(sourceArchivedId)'/>
                      <stanza-id xmlns='urn:xmpp:sid:0' by='\(groupchatJid)' id='\(sourceArchivedId)'/>
                      <time xmlns='https://xabber.com/protocol/delivery' by='\(groupchatJid)' stamp='\(sourceDate)'/>
                      <reference xmlns='https://xabber.com/protocol/references' end='21' begin='0' type='mutable'/>
                      <x xmlns='https://xabber.com/protocol/groups'>
                        <user id='author-1'>
                          <role>member</role>
                          <nickname>Careful Sea Slug 23</nickname>
                          <badge/>
                        </user>
                      </x>
                      <reference xmlns='https://xabber.com/protocol/references' end='25' begin='21' type='decoration'>
                        <link xmlns='https://xabber.com/protocol/markup'>xmpp:\(groupchatJid)?members;id=\(currentMemberId)</link>
                      </reference>
                      <markable xmlns='urn:xmpp:chat-markers:0'/>
                      <origin-id xmlns='urn:xmpp:sid:0' id='\(sourceMessageId)'/>
                      <body>Careful Sea Slug 23:\n@you</body>
                    </message>
                  </forwarded>
                </notification>
                <addresses xmlns='http://jabber.org/protocol/address'>
                  <address jid='\(groupchatJid)' type='ofrom'/>
                </addresses>
                <store xmlns='urn:xmpp:hints'/>
                <body xml:lang='en'>You were mentioned in \(groupchatJid) group.</body>
              </message>
              <delay from='xmppdev01.xabber.com' stamp='\(wrapperDate)' xmlns='urn:xmpp:delay'/>
            </forwarded>
          </result>
        </message>
        """)
    }

    private func insertMentionMessage(
        primary: String = "message-primary-1",
        archivedId: String = "archived-1",
        messageId: String = "origin-1",
        isRead: Bool = false,
        isDeleted: Bool = false
    ) throws -> MessageStorageItem {
        let realm = try WRealm.safe()
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = groupchatJid
        message.conversationType = .group
        message.body = "Hello @you"
        message.legacyBody = "Hello @you"
        message.displayAs = .text
        message.messageId = messageId
        message.archivedId = archivedId
        message.outgoing = false
        message.isRead = isRead
        message.isDeleted = isDeleted
        message.date = ISO8601DateFormatter().date(from: "2026-03-24T10:59:00Z")!
        message.sentDate = message.date

        let groupchatReference = MessageReferenceStorageItem()
        groupchatReference.kind = .groupchat
        groupchatReference.metadata = [
            "id": "author-1",
            "nickname": "Romeo"
        ]
        message.references.append(groupchatReference)

        let mentionReference = MessageReferenceStorageItem()
        mentionReference.kind = .mention
        mentionReference.metadata = [
            "uri": "xmpp:\(groupchatJid)?members;id=\(currentMemberId)",
            "memberId": currentMemberId,
            "groupchatJid": groupchatJid,
            "nickname": "@you"
        ]
        message.references.append(mentionReference)

        try realm.write {
            realm.add(message, update: .modified)
        }

        return message
    }

    private func insertMentionNotification(
        primary: String = "notification-primary-1",
        uniqueId: String = "notification-1",
        sourceArchivedId: String = "archived-1",
        sourceMessageId: String = "origin-1",
        isRead: Bool = false
    ) throws -> NotificationStorageItem {
        let realm = try WRealm.safe()
        let notification = NotificationStorageItem()
        notification.primary = primary
        notification.owner = owner
        notification.jid = groupchatAuthorJid
        notification.uniqueId = uniqueId
        notification.messageId = uniqueId
        notification.originalSenderJid = groupchatAuthorJid
        notification.associatedJid = groupchatJid
        notification.category = .mention
        notification.isRead = isRead
        notification.shouldShow = true
        notification.text = "Hello @you"
        notification.date = ISO8601DateFormatter().date(from: "2026-03-24T11:00:00Z")!
        notification.sourceConversationType = .group
        notification.sourceChatJid = groupchatJid
        notification.sourceArchivedId = sourceArchivedId
        notification.sourceMessageId = sourceMessageId
        notification.sourceSenderId = "author-1"
        notification.mentionTargetUserId = currentMemberId
        notification.sourceMessageDate = ISO8601DateFormatter().date(from: "2026-03-24T10:59:00Z")
        notification.sourceBodyFingerprint = MentionNotificationSync.normalizedBodyFingerprint("Hello @you")
        notification.mentionLinkStatus = .pending

        try realm.write {
            realm.add(notification, update: .modified)
        }

        return notification
    }

    private func insertOutgoingGroupchatMessage(
        primary: String = "outgoing-message-primary-1",
        messageId: String = "origin-1",
        body: String = "test nick",
        mentionedMemberId: String? = nil
    ) throws -> MessageStorageItem {
        let realm = try WRealm.safe()
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = groupchatJid
        message.conversationType = .group
        message.body = body
        message.legacyBody = body
        message.displayAs = .text
        message.messageId = messageId
        message.outgoing = true
        message.state = .sending
        message.date = ISO8601DateFormatter().date(from: "2026-03-24T10:58:30Z")!
        message.sentDate = message.date

        if let mentionedMemberId {
            let mentionReference = MessageReferenceStorageItem()
            mentionReference.kind = .mention
            mentionReference.begin = 0
            mentionReference.end = body.count
            mentionReference.metadata = [
                "uri": "xmpp:\(groupchatJid)?members;id=\(mentionedMemberId)",
                "memberId": mentionedMemberId,
                "groupchatJid": groupchatJid,
                "nickname": body
            ]
            message.references.append(mentionReference)
        }

        try realm.write {
            realm.add(message, update: .modified)
        }

        return message
    }

    func testParsePayloadUsesOriginalSenderAndFallbackText() throws {
        let message = try makeMessage(xml: """
        <message type='chat' from='notifications.xmppdev01.xabber.com' to='\(owner)' id='notif-1'>
          <notification xmlns='urn:xabber:xen:0' type='alert' category='security'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='security@xmppdev01.xabber.com' to='\(owner)'>
                <nick xmlns='http://jabber.org/protocol/nick'>Security Bot</nick>
                <body>Login from Chrome on macOS</body>
                <device id='device-1'/>
              </message>
            </forwarded>
          </notification>
          <body>Fallback security text</body>
          <addresses xmlns='http://jabber.org/protocol/address'>
            <address type='ofrom' jid='security@xmppdev01.xabber.com'/>
          </addresses>
          <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='2026-03-24T10:15:30Z'/>
        </message>
        """)

        let payload = XMPPNotificationsManager.parsePayload(from: message, owner: owner)

        XCTAssertEqual(payload?.jid, "security@xmppdev01.xabber.com")
        XCTAssertEqual(payload?.originalSenderJid, "security@xmppdev01.xabber.com")
        XCTAssertEqual(payload?.category, .device)
        XCTAssertEqual(payload?.notificationType, "alert")
        XCTAssertEqual(payload?.fallbackText, "Fallback security text")
        XCTAssertEqual(payload?.displayNick, "Security Bot")
        XCTAssertEqual(payload?.text, "Login from Chrome on macOS")
    }

    func testParsePayloadRejectsMismatchedOriginalSender() throws {
        let message = try makeMessage(xml: """
        <message type='chat' from='notifications.xmppdev01.xabber.com' to='\(owner)' id='notif-2'>
          <notification xmlns='urn:xabber:xen:0' type='alert' category='security'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='wrong@xmppdev01.xabber.com' to='\(owner)'>
                <body>Suspicious login</body>
                <device id='device-2'/>
              </message>
            </forwarded>
          </notification>
          <addresses xmlns='http://jabber.org/protocol/address'>
            <address type='ofrom' jid='security@xmppdev01.xabber.com'/>
          </addresses>
          <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='2026-03-24T10:15:30Z'/>
        </message>
        """)

        XCTAssertNil(XMPPNotificationsManager.parsePayload(from: message, owner: owner))
    }

    func testReadStoresNewNotificationsAsUnread() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let oldNotification = NotificationStorageItem()
            oldNotification.primary = NotificationStorageItem.genPrimary(owner: owner, jid: "security@xmppdev01.xabber.com", uniqueId: "old")
            oldNotification.owner = owner
            oldNotification.jid = "security@xmppdev01.xabber.com"
            oldNotification.uniqueId = "old"
            oldNotification.messageId = "old"
            oldNotification.category = .device
            oldNotification.isRead = true
            oldNotification.shouldShow = true
            oldNotification.date = ISO8601DateFormatter().date(from: "2026-03-23T10:00:00Z")!
            realm.add(oldNotification)
        }

        let manager = XMPPNotificationsManager(withOwner: owner)
        let message = try makeMessage(xml: """
        <message type='chat' from='notifications.xmppdev01.xabber.com' to='\(owner)' id='notif-3'>
          <notification xmlns='urn:xabber:xen:0' type='alert' category='security'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='security@xmppdev01.xabber.com' to='\(owner)'>
                <body>New login</body>
                <device id='device-3'/>
              </message>
            </forwarded>
          </notification>
          <addresses xmlns='http://jabber.org/protocol/address'>
            <address type='ofrom' jid='security@xmppdev01.xabber.com'/>
          </addresses>
          <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='2026-03-24T10:15:30Z'/>
        </message>
        """)

        XCTAssertTrue(manager.read(withMessage: message))

        let stored = try WRealm.safe()
            .objects(NotificationStorageItem.self)
            .filter("owner == %@ AND uniqueId != %@", owner, "old")
            .first
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.isRead, false)
        XCTAssertEqual(stored?.notificationType, "alert")
        XCTAssertEqual(stored?.originalSenderJid, "security@xmppdev01.xabber.com")
    }

    func testCountersAndDatasourceIncludeMentions() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let mention = NotificationStorageItem()
            mention.primary = NotificationStorageItem.genPrimary(owner: owner, jid: "romeo@xmppdev01.xabber.com", uniqueId: "mention-1")
            mention.owner = owner
            mention.jid = "romeo@xmppdev01.xabber.com"
            mention.originalSenderJid = "romeo@xmppdev01.xabber.com"
            mention.uniqueId = "mention-1"
            mention.messageId = "mention-1"
            mention.category = .mention
            mention.isRead = false
            mention.shouldShow = true
            mention.text = "You have been mentioned"
            mention.date = ISO8601DateFormatter().date(from: "2026-03-24T11:00:00Z")!
            realm.add(mention)

            let roster = RosterStorageItem()
            roster.primary = RosterStorageItem.genPrimary(jid: "romeo@xmppdev01.xabber.com", owner: owner)
            roster.owner = owner
            roster.jid = "romeo@xmppdev01.xabber.com"
            roster.username = "Romeo"
            realm.add(roster)
        }

        let counters = NotificationsSupport.unreadCounters(in: try WRealm.safe(), owners: [owner])
        XCTAssertEqual(counters.total, 1)
        XCTAssertEqual(counters.mentions, 1)

        let controller = NotificationsListViewController()
        let snapshot = controller.buildDatasourceSnapshot(filter: .mentions, filterAccount: owner)
        let rows = snapshot.flatMap(\.childs).filter { !$0.isHeader }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.category, .mention)
        XCTAssertEqual(rows.first?.title.string, "Romeo mentioned you")
    }

    func testParsePayloadForMentionIncludesStructuredSourceLinkage() throws {
        try insertGroupchatContext()
        let message = try makeMentionNotificationMessage(wrapperId: "notif-mention-1")

        let payload = XMPPNotificationsManager.parsePayload(from: message, owner: owner)

        XCTAssertEqual(payload?.category, .mention)
        XCTAssertEqual(payload?.metadata?["sourceChatJid"] as? String, groupchatJid)
        XCTAssertEqual(payload?.metadata?["sourceArchivedId"] as? String, "archived-1")
        XCTAssertEqual(payload?.metadata?["sourceMessageId"] as? String, "origin-1")
        XCTAssertEqual(payload?.metadata?["sourceSenderId"] as? String, "author-1")
        XCTAssertEqual(payload?.metadata?["mentionTargetUserId"] as? String, currentMemberId)
    }

    func testParsePayloadForMentionBackfillsTargetUserFromCanonicalGroupMemberStorage() throws {
        try insertGroupchatMemberContext()
        let message = try makeMentionNotificationMessage(wrapperId: "notif-mention-from-groupcard")

        let payload = XMPPNotificationsManager.parsePayload(from: message, owner: owner)

        XCTAssertEqual(payload?.category, .mention)
        XCTAssertEqual(payload?.metadata?["mentionTargetUserId"] as? String, currentMemberId)
    }

    func testParsePayloadRecognizesArchivedCategoryBasedMentionWithoutNestedMentionNode() throws {
        try insertGroupchatContext()
        let message = try makeArchivedCategoryMentionNotificationMessage()

        let payload = XMPPNotificationsManager.parsePayload(from: message, owner: owner)

        XCTAssertEqual(payload?.category, .mention)
        XCTAssertEqual(payload?.jid, groupchatJid)
        XCTAssertEqual(payload?.originalSenderJid, groupchatJid)
        XCTAssertEqual(payload?.text, "Careful Sea Slug 23:\n@you")
        XCTAssertEqual(payload?.metadata?["sourceChatJid"] as? String, groupchatJid)
        XCTAssertEqual(payload?.metadata?["sourceArchivedId"] as? String, "1774446425449434")
        XCTAssertEqual(payload?.metadata?["sourceMessageId"] as? String, "dc27b589374e6db3")
        XCTAssertEqual(payload?.metadata?["sourceSenderId"] as? String, "author-1")
        XCTAssertEqual(payload?.metadata?["mentionTargetUserId"] as? String, currentMemberId)
    }

    func testParsePayloadRecognizesCategoryBasedInfoNotificationWithoutNestedInfoNode() throws {
        let message = try makeMessage(xml: """
        <message type='chat' from='\(notificationsNode)' to='\(owner)' id='notif-info-category'>
          <notification xmlns='urn:xabber:xen:0' type='alert' category='info'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message type='chat' from='info@xmppdev01.xabber.com' to='\(owner)'>
                <body>Server maintenance tonight</body>
              </message>
            </forwarded>
          </notification>
          <body>Fallback info text</body>
          <addresses xmlns='http://jabber.org/protocol/address'>
            <address type='ofrom' jid='info@xmppdev01.xabber.com'/>
          </addresses>
          <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='2026-03-24T12:15:30Z'/>
        </message>
        """)

        let payload = XMPPNotificationsManager.parsePayload(from: message, owner: owner)

        XCTAssertEqual(payload?.category, .info)
        XCTAssertEqual(payload?.jid, "info@xmppdev01.xabber.com")
        XCTAssertEqual(payload?.text, "Server maintenance tonight")
    }

    func testReadDeduplicatesMentionNotificationsBySourceMessage() throws {
        try insertGroupchatContext()
        let manager = XMPPNotificationsManager(withOwner: owner)
        let first = try makeMentionNotificationMessage(wrapperId: "notif-mention-1")
        let duplicate = try makeMentionNotificationMessage(
            wrapperId: "notif-mention-2",
            wrapperDate: "2026-03-24T11:05:00Z"
        )

        XCTAssertTrue(manager.read(withMessage: first))
        XCTAssertTrue(manager.read(withMessage: duplicate))

        let notifications = try WRealm.safe()
            .objects(NotificationStorageItem.self)
            .filter("owner == %@ AND category_ == %@", owner, XMPPNotificationsManager.Category.mention.rawValue)
            .toArray()

        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.sourceArchivedId, "archived-1")
        XCTAssertEqual(notifications.first?.messageId, "notif-mention-2")
    }

    func testReadStoresArchivedCategoryBasedMentionAsNotificationItem() throws {
        try insertGroupchatContext()
        let manager = XMPPNotificationsManager(withOwner: owner)
        let message = try makeArchivedCategoryMentionNotificationMessage()

        XCTAssertTrue(manager.read(withMessage: message))

        let stored = try XCTUnwrap(
            try WRealm.safe()
                .objects(NotificationStorageItem.self)
                .filter("owner == %@ AND category_ == %@", owner, XMPPNotificationsManager.Category.mention.rawValue)
                .first
        )

        XCTAssertEqual(stored.originalSenderJid, groupchatJid)
        XCTAssertEqual(stored.associatedJid, groupchatJid)
        XCTAssertEqual(stored.stanzaId, "1774446425469615")
        XCTAssertEqual(stored.sourceChatJid, groupchatJid)
        XCTAssertEqual(stored.sourceArchivedId, "1774446425449434")
        XCTAssertEqual(stored.sourceMessageId, "dc27b589374e6db3")
        XCTAssertEqual(stored.sourceSenderId, "author-1")
        XCTAssertEqual(stored.text, "Careful Sea Slug 23:\n@you")
    }

    func testReadMentionNotificationUpdatesLastChatMentionIdFromUnreadNotifications() throws {
        try insertGroupchatContext()
        let manager = XMPPNotificationsManager(withOwner: owner)

        XCTAssertTrue(manager.read(withMessage: try makeMentionNotificationMessage(wrapperId: "notif-mention-last-chat")))

        let chat = try XCTUnwrap(
            try WRealm.safe().object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: groupchatJid, owner: owner, conversationType: .group)
            )
        )

        XCTAssertEqual(chat.mentionId, "archived-1")
    }

    func testReadMentionNotificationReconcilesFreshUnreadMentionAgainstStoredMessage() throws {
        try insertGroupchatContext()
        _ = try insertMentionMessage()
        let manager = XMPPNotificationsManager(withOwner: owner)

        XCTAssertTrue(manager.read(withMessage: try makeMentionNotificationMessage(wrapperId: "notif-mention-reconcile")))

        let stored = try XCTUnwrap(
            try WRealm.safe()
                .objects(NotificationStorageItem.self)
                .filter("owner == %@ AND category_ == %@", owner, XMPPNotificationsManager.Category.mention.rawValue)
                .first
        )

        XCTAssertEqual(stored.mentionLinkStatus, .resolved)
        XCTAssertEqual(stored.sourceBodyFingerprint, MentionNotificationSync.normalizedBodyFingerprint("Hello @you"))
        XCTAssertEqual(stored.sourceChatJid, groupchatJid)
        XCTAssertEqual(stored.sourceArchivedId, "archived-1")
        XCTAssertEqual(stored.sourceMessageId, "origin-1")
    }

    func testMentionsFilterShowsArchivedCategoryBasedMentionNotification() throws {
        try insertGroupchatContext()
        let manager = XMPPNotificationsManager(withOwner: owner)

        XCTAssertTrue(manager.read(withMessage: try makeArchivedCategoryMentionNotificationMessage()))

        let controller = NotificationsListViewController()
        let snapshot = controller.buildDatasourceSnapshot(filter: .mentions, filterAccount: owner)
        let rows = snapshot.flatMap(\.childs).filter { !$0.isHeader }

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.category, .mention)
        XCTAssertEqual(rows.first?.message?.string, "Careful Sea Slug 23:\n@you")
    }

    func testMentionOpenRequestUsesOriginalMessageAnchorMetadataInsteadOfOuterNotificationIdentity() throws {
        let notification = NotificationStorageItem()
        notification.primary = "notification-route-1"
        notification.owner = owner
        notification.jid = notificationsNode
        notification.associatedJid = "fallback-chat@example.com"
        notification.uniqueId = "outer-unique-id"
        notification.messageId = "outer-notification-id"
        notification.category = .mention
        notification.sourceConversationType = .group
        notification.sourceChatJid = groupchatJid
        notification.sourceArchivedId = "inner-archived-id"
        notification.sourceMessageId = "inner-origin-id"
        notification.sourceSenderId = "author-1"
        notification.sourceBodyFingerprint = MentionNotificationSync.normalizedBodyFingerprint("Hello @you")
        notification.sourceMessageDate = ISO8601DateFormatter().date(from: "2026-03-24T10:59:00Z")

        let request = try XCTUnwrap(NotificationsListViewController.mentionOpenRequest(for: notification))

        XCTAssertEqual(request.chatJid, groupchatJid)
        XCTAssertEqual(request.conversationType, .group)
        XCTAssertEqual(request.anchor.archivedId, "inner-archived-id")
        XCTAssertEqual(request.anchor.messageId, "inner-origin-id")
        XCTAssertEqual(request.anchor.authorId, "author-1")
        XCTAssertEqual(request.anchor.bodyFingerprint, MentionNotificationSync.normalizedBodyFingerprint("Hello @you"))
        XCTAssertEqual(request.anchor.sourceDate, ISO8601DateFormatter().date(from: "2026-03-24T10:59:00Z")!)
        XCTAssertEqual(request.source, .mentionNotification)
        XCTAssertNotEqual(request.anchor.messageId, notification.messageId)
        XCTAssertNotEqual(request.chatJid, notification.jid)
    }

    func testCategoryDatasourceCountsVisibleMentionsEvenWhenTheyAreRead() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let mention = NotificationStorageItem()
            mention.primary = NotificationStorageItem.genPrimary(owner: owner, jid: groupchatJid, uniqueId: "mention-visible")
            mention.owner = owner
            mention.jid = groupchatJid
            mention.uniqueId = "mention-visible"
            mention.messageId = "mention-visible"
            mention.category = .mention
            mention.isRead = true
            mention.shouldShow = true
            mention.text = "Archived mention"
            mention.date = ISO8601DateFormatter().date(from: "2026-03-25T13:47:05Z")!
            realm.add(mention, update: .modified)
        }

        let state = NotificationsListCoordinator.deriveState(
            realm: realm,
            owners: [owner],
            filter: .all,
            filterAccount: nil,
            headerBuilder: { _ in nil },
            listMapper: { _, _ in [] }
        )

        let mentionCategory = state.categoriesDatasource
            .flatMap { $0 }
            .first(where: { $0.key == "mentions" && !$0.isHeader })

        XCTAssertEqual(state.counters.mentions, 0)
        XCTAssertEqual(mentionCategory?.subtitle, "1")
    }

    func testExistingMentionNotificationDoesNotDeduplicateDistinctBodiesWithSameSenderAndTimestamp() throws {
        let realm = try WRealm.safe()
        let first = NotificationStorageItem()
        first.primary = "mention-first"
        first.owner = owner
        first.jid = groupchatAuthorJid
        first.uniqueId = "mention-first"
        first.messageId = "mention-first"
        first.category = .mention
        first.sourceChatJid = groupchatJid
        first.sourceSenderId = "author-1"
        first.sourceMessageDate = ISO8601DateFormatter().date(from: "2026-03-24T10:59:00Z")
        first.sourceBodyFingerprint = "hello @you"

        try realm.write {
            realm.add(first, update: .modified)
        }

        let matched = MentionNotificationSync.existingMentionNotification(
            owner: owner,
            metadata: [
                "sourceChatJid": groupchatJid,
                "sourceSenderId": "author-1",
                "sourceMessageDate": ISO8601DateFormatter().date(from: "2026-03-24T10:59:00Z")!.timeIntervalSince1970,
                "sourceBodyFingerprint": "another body"
            ],
            in: realm
        )

        XCTAssertNil(matched)
    }

    func testMentionNotificationReconcileKeepsUnreadWhenLinkedMessageIsRead() throws {
        try insertGroupchatContext()
        _ = try insertMentionMessage(isRead: true)
        let notification = try insertMentionNotification()
        let realm = try WRealm.safe()

        try realm.write {
            _ = MentionNotificationSync.reconcile(notification: notification, in: realm)
        }

        XCTAssertFalse(notification.isRead)
        XCTAssertEqual(notification.mentionLinkStatus, .resolved)
        XCTAssertEqual(notification.sourceChatJid, groupchatJid)
    }

    func testReadNotificationPropagatesToLinkedMessageOnceMessageAppears() throws {
        try insertGroupchatContext()
        let message = try insertMentionMessage(isRead: false)
        _ = try insertMentionNotification(isRead: true)
        let realm = try WRealm.safe()

        var primariesToMarkRead: Set<String> = []
        try realm.write {
            primariesToMarkRead = MentionNotificationSync.reconcileMentionNotifications(
                for: owner,
                chats: [groupchatJid],
                in: realm
            )
        }

        XCTAssertEqual(primariesToMarkRead, [message.primary])
    }

    func testMessageReadKeepsLinkedMentionNotificationUnreadAndMentionIdVisible() throws {
        try insertGroupchatContext()
        let message = try insertMentionMessage(isRead: false)
        _ = try insertMentionNotification(isRead: false)

        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.readMessage(message.primary, last: false)

        let realm = try WRealm.safe()
        let notification = realm
            .objects(NotificationStorageItem.self)
            .filter("owner == %@ AND category_ == %@", owner, XMPPNotificationsManager.Category.mention.rawValue)
            .first

        let chat = realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: groupchatJid, owner: owner, conversationType: .group)
        )

        XCTAssertEqual(notification?.isRead, false)
        XCTAssertEqual(chat?.mentionId, "archived-1")
    }

    func testDeletedMentionMessageInvalidatesLinkedNotification() throws {
        try insertGroupchatContext()
        _ = try insertMentionMessage(isRead: false, isDeleted: true)
        let notification = try insertMentionNotification(isRead: false)
        let realm = try WRealm.safe()

        try realm.write {
            _ = MentionNotificationSync.reconcile(notification: notification, in: realm)
        }

        XCTAssertEqual(notification.mentionLinkStatus, .missing)
        XCTAssertFalse(notification.shouldShow)
        XCTAssertTrue(notification.isRead)
    }

    func testMentionNotificationWithoutResolvedTargetRemainsPending() throws {
        let realm = try WRealm.safe()
        let message = MessageStorageItem()
        message.primary = "message-primary-pending"
        message.owner = owner
        message.opponent = groupchatJid
        message.conversationType = .group
        message.body = "Hello @you"
        message.legacyBody = "Hello @you"
        message.displayAs = .text
        message.messageId = "origin-pending"
        message.archivedId = "archived-pending"
        message.outgoing = false
        message.isRead = false
        message.date = ISO8601DateFormatter().date(from: "2026-03-24T10:59:00Z")!
        message.sentDate = message.date

        let mentionReference = MessageReferenceStorageItem()
        mentionReference.kind = .mention
        mentionReference.metadata = [
            "uri": "xmpp:\(groupchatJid)?members;id=\(currentMemberId)",
            "memberId": currentMemberId,
            "groupchatJid": groupchatJid,
            "nickname": "@you"
        ]
        message.references.append(mentionReference)

        let notification = NotificationStorageItem()
        notification.primary = "notification-pending"
        notification.owner = owner
        notification.jid = groupchatAuthorJid
        notification.uniqueId = "notification-pending"
        notification.messageId = "notification-pending"
        notification.category = .mention
        notification.isRead = false
        notification.shouldShow = true
        notification.sourceConversationType = .group
        notification.sourceChatJid = groupchatJid
        notification.sourceArchivedId = "archived-pending"
        notification.sourceMessageId = "origin-pending"
        notification.sourceSenderId = "author-1"
        notification.sourceMessageDate = message.date
        notification.sourceBodyFingerprint = MentionNotificationSync.normalizedBodyFingerprint("Hello @you")

        try realm.write {
            realm.add(message, update: .modified)
            realm.add(notification, update: .modified)
        }

        try realm.write {
            _ = MentionNotificationSync.reconcile(notification: notification, in: realm)
        }

        XCTAssertEqual(notification.mentionLinkStatus, .pending)
        XCTAssertNil(notification.linkedAt)
        XCTAssertFalse(notification.isRead)
        XCTAssertTrue(notification.shouldShow)
    }

    func testGroupchatHeadlineEchoParsesForwardedMentionedMessage() throws {
        let stored = try insertOutgoingGroupchatMessage(messageId: "oRBg707A", mentionedMemberId: "ck9akic0tlytovth")
        let manager = ReliableMessageDeliveryManager(withOwner: owner)
        let headline = try makeMessage(xml: """
        <message xmlns='jabber:client' to='\(owner)/xabber-ios-AAA91B0C' from='\(groupchatJid)/Group' type='headline'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' lang='ru' to='\(groupchatJid)/Group' from='\(owner)/xabber-ios-3294E1D4_ui_upgrade_task' type='chat' id='oRBg707A'>
                <archived xmlns='urn:xmpp:mam:tmp' by='\(groupchatJid)' id='1775561340723093'/>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(groupchatJid)' id='1775561340723093'/>
                <time xmlns='https://xabber.com/protocol/delivery' by='\(groupchatJid)' stamp='2026-04-07T11:29:00.723093Z'/>
                <reference xmlns='https://xabber.com/protocol/references' end='29' begin='0' type='mutable'/>
                <x xmlns='https://xabber.com/protocol/groups'>
                  <user id='jwwbsu8dnxnc24ye'>
                    <role>owner</role>
                    <nickname>\(owner)</nickname>
                    <badge/>
                    <jid>\(owner)</jid>
                  </user>
                </x>
                <reference xmlns='https://xabber.com/protocol/references' end='40' begin='30' type='decoration'>
                  <link xmlns='https://xabber.com/protocol/markup'>xmpp:\(groupchatJid)?members;id=ck9akic0tlytovth</link>
                </reference>
                <origin-id xmlns='urn:xmpp:sid:0' id='oRBg707A'/>
                <markable xmlns='urn:xmpp:chat-markers:0'/>
                <body>\(owner):&#10; @test nick </body>
              </message>
            </forwarded>
          </x>
        </message>
        """)

        XCTAssertTrue(manager.read(headline: headline))
        manager.parseEcho(headline)

        let updated = try XCTUnwrap(try WRealm.safe().object(ofType: MessageStorageItem.self, forPrimaryKey: stored.primary))
        let mention = updated.references.first(where: { $0.kind == .mention })
        let author = updated.references.first(where: { $0.kind == .groupchat })

        XCTAssertEqual(updated.state, .deliver)
        XCTAssertEqual(updated.archivedId, "1775561340723093")
        XCTAssertEqual(updated.body, "test nick")
        XCTAssertEqual(mention?.begin, 0)
        XCTAssertEqual(mention?.end, 9)
        XCTAssertEqual(mention?.metadata?["memberId"] as? String, "ck9akic0tlytovth")
        XCTAssertEqual(mention?.metadata?["groupchatJid"] as? String, groupchatJid)
        XCTAssertEqual(author?.metadata?["id"] as? String, "jwwbsu8dnxnc24ye")
    }

    func testAccountFilteringUsesOnlySelectedOwnersNotifications() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let first = NotificationStorageItem()
            first.primary = NotificationStorageItem.genPrimary(owner: owner, jid: "first@xmppdev01.xabber.com", uniqueId: "first")
            first.owner = owner
            first.jid = "first@xmppdev01.xabber.com"
            first.uniqueId = "first"
            first.messageId = "first"
            first.category = .info
            first.isRead = false
            first.shouldShow = true
            first.date = ISO8601DateFormatter().date(from: "2026-03-24T08:00:00Z")!
            realm.add(first)

            let secondOwner = "second@xmppdev01.xabber.com"
            let second = NotificationStorageItem()
            second.primary = NotificationStorageItem.genPrimary(owner: secondOwner, jid: "second@xmppdev01.xabber.com", uniqueId: "second")
            second.owner = secondOwner
            second.jid = "second@xmppdev01.xabber.com"
            second.uniqueId = "second"
            second.messageId = "second"
            second.category = .info
            second.isRead = false
            second.shouldShow = true
            second.date = ISO8601DateFormatter().date(from: "2026-03-24T09:00:00Z")!
            realm.add(second)
        }

        let filtered = NotificationsSupport.notifications(in: try WRealm.safe(), owners: [owner], filter: .all, unreadOnly: true).toArray()
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.owner, owner)
    }

    func testReadMergesArchiveMetadataIntoExistingDuplicateNotification() throws {
        _ = try insertNotification(uniqueId: "notif-archive-1", stanzaId: nil, date: "2026-03-24T10:15:30Z")
        let manager = XMPPNotificationsManager(withOwner: owner)
        let archivedMessage = try makeArchivedInfoNotificationMessage(
            wrapperId: "notif-archive-1",
            stanzaId: "archive-stanza-1"
        )

        XCTAssertTrue(manager.read(withMessage: archivedMessage))

        let notifications = try WRealm.safe()
            .objects(NotificationStorageItem.self)
            .filter("owner == %@", owner)
            .toArray()

        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.stanzaId, "archive-stanza-1")
        XCTAssertEqual(try managerStorage()?.lastSyncedNotificationId, "archive-stanza-1")
    }

    func testReadNotificationUsesUnreadBoundaryFromStorageInsteadOfDateFallback() throws {
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            unread: 1,
            unreadAfterId: "1776509222888890"
        )
        _ = try insertNotification(
            uniqueId: "older-read-notification",
            stanzaId: "1776509222888890",
            date: "2026-03-26T10:15:30Z"
        )
        let realm = try WRealm.safe()
        try realm.write {
            realm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: NotificationStorageItem.genPrimary(
                    owner: owner,
                    jid: "security@xmppdev01.xabber.com",
                    uniqueId: "older-read-notification"
                )
            )?.isRead = true
        }

        let manager = XMPPNotificationsManager(withOwner: owner)
        XCTAssertTrue(
            manager.read(
                withMessage: try makeArchivedInfoNotificationMessage(
                    wrapperId: "notif-boundary-newer",
                    stanzaId: "1776840442467416",
                    date: "2026-03-24T10:15:30Z"
                )
            )
        )

        let notification = try XCTUnwrap(
            try WRealm.safe().object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: NotificationStorageItem.genPrimary(
                    owner: owner,
                    jid: "security@xmppdev01.xabber.com",
                    uniqueId: "notif-boundary-newer"
                )
            )
        )
        XCTAssertFalse(notification.isRead)
    }

    func testReadNotificationUsesArchivedFallbackIdForUnreadBoundaryComparison() throws {
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            unread: 1,
            unreadAfterId: "1776509222888890"
        )

        let manager = XMPPNotificationsManager(withOwner: owner)
        XCTAssertTrue(
            manager.read(
                withMessage: try makeArchivedInfoNotificationMessageWithoutStanzaId(
                    wrapperId: "notif-archived-fallback",
                    archivedId: "1776840442467416"
                )
            )
        )

        let notification = try XCTUnwrap(
            try WRealm.safe().object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: NotificationStorageItem.genPrimary(
                    owner: owner,
                    jid: "security@xmppdev01.xabber.com",
                    uniqueId: "notif-archived-fallback"
                )
            )
        )
        XCTAssertEqual(notification.stanzaId, "1776840442467416")
        XCTAssertFalse(notification.isRead)
    }

    func testConfigurePreservesArchiveStateWhenNodeIsRediscovered() throws {
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            archiveSyncCompleted: true,
            lastSyncedNotificationId: "oldest-archived-id"
        )

        let manager = XMPPNotificationsManager(withOwner: owner)
        manager.configure(for: notificationsNode)

        let storage = try XCTUnwrap(try managerStorage())
        XCTAssertTrue(storage.archiveSyncCompleted)
        XCTAssertEqual(storage.lastSyncedNotificationId, "oldest-archived-id")
    }

    func testConfigurePreservesLatestHighWaterCursorWhenNodeIsRediscovered() throws {
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            archiveSyncCompleted: true,
            lastSyncedNotificationId: "oldest-archived-id",
            lastItemId: "latest-scanned-id"
        )

        let manager = XMPPNotificationsManager(withOwner: owner)
        manager.configure(for: notificationsNode)

        let storage = try XCTUnwrap(try managerStorage())
        XCTAssertEqual(storage.lastItemId, "latest-scanned-id")
        XCTAssertEqual(storage.lastSyncedNotificationId, "oldest-archived-id")
        XCTAssertTrue(storage.archiveSyncCompleted)
    }

    func testConfigureResetsArchiveStateWhenNodeChangesButKeepsStoredNotifications() throws {
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            archiveSyncCompleted: true,
            lastSyncedNotificationId: "oldest-archived-id",
            lastItemId: "latest-scanned-id"
        )
        _ = try insertNotification(uniqueId: "notif-1", stanzaId: "archive-1", date: "2026-03-24T10:15:30Z")

        let manager = XMPPNotificationsManager(withOwner: owner)
        manager.configure(for: "notifications-2.xmppdev01.xabber.com")

        let storage = try XCTUnwrap(try managerStorage())
        XCTAssertEqual(storage.node, "notifications-2.xmppdev01.xabber.com")
        XCTAssertFalse(storage.archiveSyncCompleted)
        XCTAssertNil(storage.lastSyncedNotificationId)
        XCTAssertNil(storage.lastItemId)
        XCTAssertEqual(
            try WRealm.safe().objects(NotificationStorageItem.self).filter("owner == %@", owner).count,
            1
        )
    }

    func testFirstLoginBootstrapLoadsNewestPageThenBackfillsOlderPagesUntilArchiveCompleted() throws {
        let account = makeAccount()
        account.notifications.node = notificationsNode
        try upsertNotificationManagerStorage(node: notificationsNode, archiveSyncCompleted: false)

        account.notifications.update(account.xmppStream)

        let latestRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(latestRequest.task.conversationType, .notifications)
        XCTAssertEqual(latestRequest.task.purpose, .latest)
        XCTAssertEqual(latestRequest.task.max, 100)
        XCTAssertNil(latestRequest.task.afterId)

        try sendArchiveFin(
            on: account,
            queryId: latestRequest.elementId,
            complete: false,
            count: 100,
            first: "archived-001",
            last: "archived-100"
        )

        let olderRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(olderRequest.task.purpose, .pageOlder)
        XCTAssertEqual(olderRequest.task.max, 100)
        XCTAssertEqual(olderRequest.task.messageId, "archived-001")

        try sendArchiveFin(
            on: account,
            queryId: olderRequest.elementId,
            complete: true,
            count: 25,
            first: "archived-older-001",
            last: "archived-older-025"
        )

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let storage = try XCTUnwrap(try managerStorage())
        XCTAssertTrue(storage.archiveSyncCompleted)
        XCTAssertEqual(storage.lastSyncedNotificationId, "archived-older-001")
        XCTAssertEqual(storage.lastItemId, "archived-100")
    }

    func testSubsequentUpdateWithCompletedArchiveRequestsLatestOnly() throws {
        let account = makeAccount()
        account.notifications.node = notificationsNode
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            archiveSyncCompleted: true,
            lastSyncedNotificationId: "archived-oldest"
        )
        _ = try insertNotification(uniqueId: "notif-old", stanzaId: "archived-oldest", date: "2026-03-24T10:15:30Z")
        _ = try insertNotification(uniqueId: "notif-new", stanzaId: "archived-newest", date: "2026-03-24T11:15:30Z")

        account.notifications.update(account.xmppStream)

        let latestRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(latestRequest.task.purpose, .latest)
        XCTAssertEqual(latestRequest.task.afterId, "archived-newest")
        XCTAssertEqual(latestRequest.task.max, 100)

        try sendArchiveFin(
            on: account,
            queryId: latestRequest.elementId,
            complete: true,
            count: 0,
            first: "",
            last: ""
        )

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertNil(queuedNotificationRequest(on: account))
        XCTAssertTrue(try XCTUnwrap(managerStorage()).archiveSyncCompleted)
    }

    func testSubsequentUpdatePrefersPersistedLatestHighWaterCursorOverNewestStoredNotification() throws {
        let account = makeAccount()
        account.notifications.node = notificationsNode
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            archiveSyncCompleted: true,
            lastSyncedNotificationId: "archived-oldest",
            lastItemId: "latest-scanned-id"
        )
        _ = try insertNotification(uniqueId: "notif-new", stanzaId: "stale-stored-newest", date: "2026-03-24T11:15:30Z")

        account.notifications.update(account.xmppStream)

        let latestRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(latestRequest.task.purpose, .latest)
        XCTAssertEqual(latestRequest.task.afterId, "latest-scanned-id")

        try sendArchiveFin(
            on: account,
            queryId: latestRequest.elementId,
            complete: true,
            count: 0,
            first: "",
            last: ""
        )
    }

    func testLatestPaginationPersistsHighWaterCursorSoNextStartDoesNotRescanSamePages() throws {
        var account = makeAccount()
        account.notifications.node = notificationsNode
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            archiveSyncCompleted: true,
            lastSyncedNotificationId: "archived-oldest"
        )
        _ = try insertNotification(
            uniqueId: "notif-new",
            stanzaId: "1716893716816619",
            date: "2026-03-24T11:15:30Z"
        )

        account.notifications.update(account.xmppStream)

        let firstLatestRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(firstLatestRequest.task.afterId, "1716893716816619")
        let notificationCountBeforePage = try WRealm.safe()
            .objects(NotificationStorageItem.self)
            .filter("owner == %@", owner)
            .count

        try sendArchiveFin(
            on: account,
            queryId: firstLatestRequest.elementId,
            complete: false,
            count: 101,
            first: "page-1-first",
            last: "1723199402526186"
        )

        let secondLatestRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(secondLatestRequest.task.purpose, .latest)
        XCTAssertEqual(secondLatestRequest.task.afterId, "1723199402526186")
        XCTAssertEqual(try managerStorage()?.lastItemId, "1723199402526186")
        XCTAssertEqual(
            try WRealm.safe()
                .objects(NotificationStorageItem.self)
                .filter("owner == %@", owner)
                .count,
            notificationCountBeforePage
        )

        try sendArchiveFin(
            on: account,
            queryId: secondLatestRequest.elementId,
            complete: true,
            count: 0,
            first: "",
            last: ""
        )

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        account = makeAccount()
        account.notifications.update(account.xmppStream)

        let restartLatestRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(restartLatestRequest.task.purpose, .latest)
        XCTAssertEqual(restartLatestRequest.task.afterId, "1723199402526186")
        XCTAssertNotEqual(restartLatestRequest.task.afterId, "1716893716816619")
    }

    func testLatestPaginationAdvancesHighWaterCursorAcrossMultiplePages() throws {
        let account = makeAccount()
        account.notifications.node = notificationsNode
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            archiveSyncCompleted: true,
            lastSyncedNotificationId: "archived-oldest",
            lastItemId: "latest-before-sync"
        )

        account.notifications.update(account.xmppStream)

        let firstRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(firstRequest.task.afterId, "latest-before-sync")

        try sendArchiveFin(
            on: account,
            queryId: firstRequest.elementId,
            complete: false,
            count: 101,
            first: "page-1-first",
            last: "page-1-last"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(try managerStorage()?.lastItemId, "page-1-last")

        let secondRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(secondRequest.task.afterId, "page-1-last")

        try sendArchiveFin(
            on: account,
            queryId: secondRequest.elementId,
            complete: false,
            count: 101,
            first: "page-2-first",
            last: "page-2-last"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(try managerStorage()?.lastItemId, "page-2-last")

        let thirdRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(thirdRequest.task.afterId, "page-2-last")

        try sendArchiveFin(
            on: account,
            queryId: thirdRequest.elementId,
            complete: true,
            count: 0,
            first: "",
            last: ""
        )

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(try managerStorage()?.lastItemId, "page-2-last")
        XCTAssertNil(queuedNotificationRequest(on: account))
    }

    func testFinalLatestPageWithNonEmptyLastPersistsFinalHighWaterCursor() throws {
        let account = makeAccount()
        account.notifications.node = notificationsNode
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            archiveSyncCompleted: true,
            lastSyncedNotificationId: "archived-oldest",
            lastItemId: "latest-before-final-page"
        )

        account.notifications.update(account.xmppStream)

        let request = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(request.task.afterId, "latest-before-final-page")

        try sendArchiveFin(
            on: account,
            queryId: request.elementId,
            complete: true,
            count: 2,
            first: "final-page-first",
            last: "final-page-last"
        )

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertEqual(try managerStorage()?.lastItemId, "final-page-last")
        XCTAssertNil(queuedNotificationRequest(on: account))
    }

    func testSubsequentUpdateResumesBackfillAfterLatestWhenArchiveIsIncomplete() throws {
        let account = makeAccount()
        account.notifications.node = notificationsNode
        try upsertNotificationManagerStorage(
            node: notificationsNode,
            archiveSyncCompleted: false,
            lastSyncedNotificationId: "archived-oldest"
        )
        _ = try insertNotification(uniqueId: "notif-old", stanzaId: "archived-oldest", date: "2026-03-24T10:15:30Z")
        _ = try insertNotification(uniqueId: "notif-new", stanzaId: "archived-newest", date: "2026-03-24T11:15:30Z")

        account.notifications.update(account.xmppStream)

        let latestRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(latestRequest.task.purpose, .latest)
        XCTAssertEqual(latestRequest.task.afterId, "archived-newest")

        try sendArchiveFin(
            on: account,
            queryId: latestRequest.elementId,
            complete: true,
            count: 1,
            first: "archived-newer-001",
            last: "archived-newer-001"
        )

        let olderRequest = waitForQueuedNotificationRequest(on: account)
        XCTAssertEqual(olderRequest.task.purpose, .pageOlder)
        XCTAssertEqual(olderRequest.task.messageId, "archived-oldest")

        try sendArchiveFin(
            on: account,
            queryId: olderRequest.elementId,
            complete: false,
            count: 0,
            first: "",
            last: ""
        )

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        let storage = try XCTUnwrap(try managerStorage())
        XCTAssertTrue(storage.archiveSyncCompleted)
        XCTAssertEqual(storage.lastSyncedNotificationId, "archived-oldest")
    }

    func testUpdateDoesNotQueueDuplicateLatestRequestsWhileSyncIsInFlight() throws {
        let account = makeAccount()
        account.notifications.node = notificationsNode
        try upsertNotificationManagerStorage(node: notificationsNode, archiveSyncCompleted: false)

        account.notifications.update(account.xmppStream)
        account.notifications.update(account.xmppStream)

        XCTAssertEqual(
            account.mam.callbacksQueue.filter { $0.task.conversationType == .notifications }.count,
            1
        )
    }
}

final class MessageReceiverBatchingTests: XCTestCase {

    private let owner = "igor.boldin@xmppdev01.xabber.com"

    private func makeMessage(id: String) throws -> XMPPMessage {
        let document = try DDXMLDocument(xmlString: """
        <message type='chat' id='\(id)' from='alexey.boldin@xmppdev01.xabber.com' to='\(owner)'>
          <body>Hello</body>
        </message>
        """, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "MessageReceiverBatchingTests", code: 1)
        }
        return XMPPMessage(from: root)
    }

    func testEnqueueCollectionBatchesIntoMessagesQueue() throws {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.unsubscribeReceiver()
        manager.clearQueue()

        let first = MessageManager.MessageQueueItem(
            try makeMessage(id: "m1"),
            messageId: "m1",
            archivedFrom: "alexey.boldin@xmppdev01.xabber.com",
            isRead: false,
            date: Date(timeIntervalSince1970: 1),
            state: .deliver,
            queryId: "history-1"
        )
        let second = MessageManager.MessageQueueItem(
            try makeMessage(id: "m2"),
            messageId: "m2",
            archivedFrom: "alexey.boldin@xmppdev01.xabber.com",
            isRead: false,
            date: Date(timeIntervalSince1970: 2),
            state: .deliver,
            queryId: "history-1"
        )

        manager.enqueue(collection: [first, second])

        XCTAssertEqual(manager.messagesQueue.value.count, 2)
    }
}

final class ChatDatasetPerformanceHelpersTests: XCTestCase {

    func testMapReferenceAttachmentsPartitionsReferencesInOnePass() {
        let image = MessageReferenceStorageItem()
        image.primary = "image"
        image.mimeType = MimeIconTypes.image.rawValue
        image.kind = .media

        let video = MessageReferenceStorageItem()
        video.primary = "video"
        video.mimeType = MimeIconTypes.video.rawValue
        video.kind = .media

        let audio = MessageReferenceStorageItem()
        audio.primary = "audio"
        audio.kind = .voice
        audio.kind_ = "voice"

        let file = MessageReferenceStorageItem()
        file.primary = "file"
        file.mimeType = "application/pdf"
        file.kind = .media
        file.name = "spec.pdf"

        let groupchatFile = MessageReferenceStorageItem()
        groupchatFile.primary = "group-file"
        groupchatFile.mimeType = "application/pdf"
        groupchatFile.kind = .media
        groupchatFile.kind_ = "groupchat"

        let result = ChatViewController.mapReferenceAttachments([image, video, audio, file, groupchatFile])

        XCTAssertEqual(result.images.map(\.primary), ["image"])
        XCTAssertEqual(result.videos.map(\.primary), ["video"])
        XCTAssertEqual(result.audio.map(\.primary), ["audio"])
        XCTAssertEqual(result.files.map(\.primary), ["file"])
    }

    func testChatDatasourceSnapshotBuildsLookupMaps() {
        let first = ChatViewController.Datasource(
            primary: "first",
            jid: "romeo@example.com",
            owner: "owner@example.com",
            outgoing: false,
            sender: Sender(id: "1", displayName: "Romeo"),
            messageId: "m1",
            sentDate: Date(),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "one")),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: false,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "a1",
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: ""),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )
        let second = ChatViewController.Datasource(
            primary: "second",
            jid: "juliet@example.com",
            owner: "owner@example.com",
            outgoing: true,
            sender: Sender(id: "2", displayName: "Juliet"),
            messageId: "m2",
            sentDate: Date(),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "two")),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: false,
            forwards: [],
            isOutgoing: true,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "a2",
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: ""),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )

        let snapshot = ChatDatasourceCoordinator.makeSnapshot(items: [first, second])

        XCTAssertEqual(snapshot.primaryIndex["first"], 0)
        XCTAssertEqual(snapshot.primaryIndex["second"], 1)
        XCTAssertEqual(snapshot.archivedIdIndex["a1"], 0)
        XCTAssertEqual(snapshot.archivedIdIndex["a2"], 1)
    }

    func testChatDatasourceSnapshotHandlesDuplicateArchivedIdsWithoutCrashing() {
        let first = ChatViewController.Datasource(
            primary: "first",
            jid: "romeo@example.com",
            owner: "owner@example.com",
            outgoing: false,
            sender: Sender(id: "1", displayName: "Romeo"),
            messageId: "m1",
            sentDate: Date(),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: "one")),
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: false,
            canEditMessage: false,
            canDeleteMessage: false,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "shared-archived-id",
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: ""),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )
        var second = first
        second.primary = "second"
        second.sender = Sender(id: "2", displayName: "Juliet")
        second.messageId = "m2"
        second.sentDate = Date().addingTimeInterval(1)

        let snapshot = ChatDatasourceCoordinator.makeSnapshot(items: [first, second])

        XCTAssertTrue(snapshot.hasDuplicateArchivedIds)
        XCTAssertEqual(snapshot.archivedIdIndex["shared-archived-id"], 1)
        XCTAssertFalse(
            ChatDatasourceCoordinator.compatibleForTargetedApply(
                old: snapshot,
                new: snapshot
            )
        )
    }
}

final class ChatBootstrapStateTests: XCTestCase {

    func testBootstrapStateShowsSkeletonWhenChatIsUnsyncedAndHasNoMessages() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 0,
                isSynced: false,
                isInitialBootstrapInFlight: false,
                hasPendingInitialAnchorRequest: false
            ),
            .skeleton
        )
    }

    func testBootstrapStateShowsEmptyWhenChatIsSyncedAndHasNoMessages() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 0,
                isSynced: true,
                isInitialBootstrapInFlight: false,
                hasPendingInitialAnchorRequest: false
            ),
            .empty
        )
    }

    func testBootstrapStateShowsSkeletonWhenChatIsSyncedButSessionBootstrapIsStillInFlight() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 0,
                isSynced: true,
                isInitialBootstrapInFlight: true,
                hasPendingInitialAnchorRequest: false
            ),
            .skeleton
        )
    }

    func testBootstrapStateKeepsSkeletonWhileInitialAnchorRequestIsStillUnresolved() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 3,
                isSynced: false,
                isInitialBootstrapInFlight: true,
                hasPendingInitialAnchorRequest: true
            ),
            .skeleton
        )
    }

    func testBootstrapStateShowsContentWhenMessagesExistBeforeArchiveBootstrapCompletes() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 3,
                isSynced: false,
                isInitialBootstrapInFlight: true,
                hasPendingInitialAnchorRequest: false
            ),
            .content
        )
    }

    func testBootstrapStateShowsContentWhenMessagesExistAfterArchiveBootstrapCompletes() {
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 3,
                isSynced: true,
                isInitialBootstrapInFlight: false,
                hasPendingInitialAnchorRequest: false
            ),
            .content
        )
    }

    func testBootstrapStateIgnoresUnsyncedFlagWhenMessagesAlreadyExist() {
        let item = LastChatsStorageItem()
        item.isSynced = false

        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 2,
                isSynced: item.isSynced,
                isInitialBootstrapInFlight: false,
                hasPendingInitialAnchorRequest: false
            ),
            .content
        )
    }
}

final class ChatInitialHistoryAppearancePolicyTests: XCTestCase {

    func testInitialAppearanceStartsWhenDatasourceIsPlaceholder() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldStart(isShowingBootstrapPlaceholder: true)
        )
    }

    func testInitialAppearanceDoesNotStartWhenDatasourceAlreadyHasContent() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldStart(isShowingBootstrapPlaceholder: false)
        )
    }

    func testInitialAppearanceKeepsDatasourceApplyNonAnimatedWhilePending() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldAnimateDatasourceApply(isInitialHistoryAppearancePending: true)
        )
    }

    func testInitialAppearanceRestoresDatasourceAnimationAfterFirstStableRender() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldAnimateDatasourceApply(isInitialHistoryAppearancePending: false)
        )
    }

    func testInitialAppearanceUsesReloadFallbackForNonAnimatedTargetedDiff() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldUseReloadFallbackForTargetedDiff(animated: false)
        )
    }

    func testPostInitialTargetedDiffKeepsIncrementalUpdates() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldUseReloadFallbackForTargetedDiff(animated: true)
        )
    }

    func testBootstrapReloadSkipsImmediateFollowupChangeset() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldApplyFollowupChangesetAfterBootstrapReload(
                didReloadInitialWindow: true
            )
        )
    }

    func testNonBootstrapTransitionsStillAllowChangesets() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldApplyFollowupChangesetAfterBootstrapReload(
                didReloadInitialWindow: false
            )
        )
    }

    func testInitialAppearanceDoesNotCompleteBeforeViewDidAppear() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                hasViewAppeared: false,
                hasRenderedStableHistory: true
            )
        )
    }

    func testInitialAppearanceDoesNotCompleteBeforeStableHistoryRender() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                hasViewAppeared: true,
                hasRenderedStableHistory: false
            )
        )
    }

    func testInitialAppearanceCompletesAfterViewDidAppearAndStableRender() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldCompleteInitialAppearance(
                hasViewAppeared: true,
                hasRenderedStableHistory: true
            )
        )
    }

    func testInitialPopulationForcesNonAnimatedApply() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldForceNonAnimatedApplyForInitialPopulation(
                oldItemCount: 0,
                newItemCount: 10
            )
        )
    }

    func testNonInitialPopulationCanStillAnimate() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldForceNonAnimatedApplyForInitialPopulation(
                oldItemCount: 4,
                newItemCount: 10
            )
        )
    }

    func testInitialAppearanceDoesNotFinishForSkeletonOnlyRender() {
        XCTAssertFalse(
            ChatInitialHistoryAppearancePolicy.shouldFinish(itemCount: 6, containsOnlyFakeMessages: true)
        )
    }

    func testInitialAppearanceFinishesForRealHistoryRender() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldFinish(itemCount: 6, containsOnlyFakeMessages: false)
        )
    }

    func testInitialAppearanceFinishesForEmptyChatRender() {
        XCTAssertTrue(
            ChatInitialHistoryAppearancePolicy.shouldFinish(itemCount: 0, containsOnlyFakeMessages: false)
        )
    }
}

final class MessageArchiveRequestClassificationTests: XCTestCase {

    private let owner = "owner@example.com"
    private let jid = "romeo@example.com"

    private func queuedTask(
        _ manager: MessageArchiveManager,
        queryId: String
    ) -> MessageArchiveManager.MAMRequestItem? {
        manager.callbacksQueue.first(where: { $0.elementId == queryId })?.task
    }

    func testBootstrapPurposeMarksInitialArchiveLoaded() {
        XCTAssertTrue(MessageArchiveManager.RequestPurpose.bootstrap.marksInitialArchiveLoaded)
    }

    func testNonBootstrapPurposesDoNotMarkInitialArchiveLoaded() {
        let purposes: [MessageArchiveManager.RequestPurpose] = [
            .pageOlder,
            .pageNewer,
            .jump,
            .gapRepair,
            .search,
            .latest,
            .media
        ]

        XCTAssertTrue(purposes.allSatisfy { !$0.marksInitialArchiveLoaded })
    }

    func testPersistedOlderCursorUsesOldestRsmBoundaryForBootstrap() {
        XCTAssertEqual(
            MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
                purpose: .bootstrap,
                first: "newest-page-boundary",
                last: "oldest-archived-id",
                current: "existing-cursor"
            ),
            "oldest-archived-id"
        )
    }

    func testPersistedOlderCursorUsesOldestRsmBoundaryForOlderPaging() {
        XCTAssertEqual(
            MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
                purpose: .pageOlder,
                first: "newest-page-boundary",
                last: "older-boundary",
                current: "existing-cursor"
            ),
            "older-boundary"
        )
    }

    func testPersistedOlderCursorDoesNotOverwriteForNewerPaging() {
        XCTAssertEqual(
            MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
                purpose: .pageNewer,
                first: "newer-boundary",
                last: "older-boundary",
                current: "existing-cursor"
            ),
            "existing-cursor"
        )
    }

    func testPersistedOlderCursorFallsBackToFirstRsmBoundaryWhenLastIsMissing() {
        XCTAssertEqual(
            MessageArchiveManager.HistoryCursorPolicy.persistedOlderCursorId(
                purpose: .pageOlder,
                first: "fallback-boundary",
                last: "",
                current: "existing-cursor"
            ),
            "fallback-boundary"
        )
    }

    func testBaselineOlderPageRequestCanMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "baseline-older"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: queryId,
            nextPage: ""
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, true)
    }

    func testBaselineBootstrapRequestCanMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "baseline-bootstrap"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .bootstrap,
            queryId: queryId,
            nextPage: ""
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, true)
    }

    func testBootstrapRequestWithArchiveStartCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "filtered-bootstrap"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .omemo,
            purpose: .bootstrap,
            queryId: queryId,
            start: Date(timeIntervalSince1970: 1234),
            nextPage: ""
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, false)
    }

    func testOlderPageRequestWithArchiveStartCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "filtered-older-start"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: true,
            conversationType: .omemo,
            purpose: .pageOlder,
            queryId: queryId,
            start: Date(timeIntervalSince1970: 1234),
            nextPage: "archived-100"
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, false)
    }

    func testBeforeIdFilteredRequestCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "before-id-filter"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: queryId,
            beforeId: "stanza-42",
            nextPage: ""
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, false)
    }

    func testAfterIdFilteredRequestCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "after-id-filter"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: queryId,
            afterId: "stanza-84",
            nextPage: ""
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, false)
    }

    func testSearchTextAndTagFiltersCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "search-tag-filter"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: queryId,
            searchText: "needle",
            nextPage: "",
            tags: [.image]
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.archiveEndEligibility, false)
    }

    func testIdsFilteredJumpRequestCannotMarkArchiveEnd() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = "ids-filter"

        manager.requestArchive(
            XMPPStream(),
            jid: jid,
            isContinues: false,
            conversationType: .regular,
            purpose: .jump,
            queryId: queryId,
            ids: ["archived-42"],
            nextPage: ""
        )

        let task = queuedTask(manager, queryId: queryId)
        XCTAssertEqual(task?.purpose, .jump)
        XCTAssertEqual(task?.archiveEndEligibility, false)
    }

    func testFetchAnchorMessageQueuesExactSingleItemJumpRequest() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = manager.fetchAnchorMessage(
            XMPPStream(),
            jid: jid,
            conversationType: .regular,
            archivedId: "archived-42",
            queryId: "jump-exact"
        )

        let task = queuedTask(manager, queryId: queryId)
        XCTAssertEqual(task?.purpose, .jump)
        XCTAssertEqual(task?.max, 1)
        XCTAssertEqual(task?.archiveEndEligibility, false)
    }
}

final class MessageArchivePagingRequestTests: XCTestCase {

    func testNewestBootstrapRequestUsesEmptyBeforePointer() {
        let request = MessageArchiveManager.newestBootstrapPageRequest(pageSize: 100)

        XCTAssertEqual(request.nextPage, "")
        XCTAssertNil(request.prevPage)
        XCTAssertEqual(request.max, 100)
    }

    func testOlderPageRequestUsesBeforePointerWithOldestLoadedId() {
        let request = MessageArchiveManager.olderPageRequest(messageId: "oldest-id", pageSize: 100)

        XCTAssertEqual(request.nextPage, "oldest-id")
        XCTAssertNil(request.prevPage)
        XCTAssertEqual(request.max, 100)
    }

    func testNewerPageRequestUsesAfterPointerWithNewestLoadedId() {
        let request = MessageArchiveManager.newerPageRequest(messageId: "newest-id", pageSize: 100)

        XCTAssertNil(request.nextPage)
        XCTAssertEqual(request.prevPage, "newest-id")
        XCTAssertEqual(request.max, 100)
    }

    func testChatHistoryPagingUsesSharedPageSizeConstant() {
        XCTAssertEqual(ChatHistoryPagingConfiguration.pageSize, 100)
    }
}

final class MessageArchiveQueryCallbackTests: XCTestCase {

    private let owner = "owner@example.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "MessageArchiveQueryCallbackTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "MessageArchiveQueryCallbackTests", code: 1)
        }
        return root
    }

    private func makeIQ(xml: String) throws -> XMPPIQ {
        XMPPIQ(from: try makeElement(xml: xml))
    }

    private func makeMessage(xml: String) throws -> XMPPMessage {
        XMPPMessage(from: try makeElement(xml: xml))
    }

    private func insertLastChat(
        jid: String = "romeo@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .regular,
        fullArchiveLoaded: Bool = false,
        lastLoadedMessageHistoryId: String? = nil
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.jid = jid
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        chat.owner = owner
        chat.fullArchiveLoaded = fullArchiveLoaded
        chat.lastLoadedMessageHistoryId = lastLoadedMessageHistoryId

        try realm.write {
            realm.add(chat, update: .modified)
        }
    }

    private func fullArchiveLoaded(
        jid: String = "romeo@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) throws -> Bool {
        let realm = try WRealm.safe()
        return realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        )?.fullArchiveLoaded ?? false
    }

    private func persistedHistoryCursorId(
        jid: String = "romeo@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) throws -> String? {
        let realm = try WRealm.safe()
        return realm.object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        )?.lastLoadedMessageHistoryId
    }

    private func queuedTask(
        _ manager: MessageArchiveManager,
        queryId: String
    ) -> MessageArchiveManager.MAMRequestItem? {
        manager.callbacksQueue.first(where: { $0.elementId == queryId })?.task
    }

    func testSyncChatDoesNotStartGapRepairForAlreadySyncedChat() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let jid = "romeo@example.com"
        let conversationType: ClientSynchronizationManager.ConversationType = .regular
        let realm = try WRealm.safe()

        let chat = LastChatsStorageItem()
        chat.jid = jid
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        chat.owner = owner
        chat.isSynced = true

        try realm.write {
            realm.add(chat, update: .modified)
        }

        let result = manager.syncChat(
            XMPPStream(),
            jid: jid,
            conversationType: conversationType,
            callback: nil
        )

        XCTAssertEqual(result, .noop)
        XCTAssertTrue(manager.callbacksQueue.isEmpty)
    }

    func testSyncChatUsesInjectedPageSizeForBootstrapRequest() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let jid = "romeo@example.com"
        let conversationType: ClientSynchronizationManager.ConversationType = .regular
        let realm = try WRealm.safe()

        let chat = LastChatsStorageItem()
        chat.jid = jid
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        chat.owner = owner
        chat.isSynced = false

        try realm.write {
            realm.add(chat, update: .modified)
        }

        let result = manager.syncChat(
            XMPPStream(),
            jid: jid,
            conversationType: conversationType,
            pageSize: 42,
            callback: nil
        )

        guard case let .bootstrapStarted(queryId) = result else {
            return XCTFail("Expected bootstrap request to start")
        }
        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.max, 42)
    }

    func testGetNextHistoryUsesInjectedPageSize() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = manager.getNextHistory(
            XMPPStream(),
            for: "romeo@example.com",
            conversationType: .regular,
            messageId: nil,
            pageSize: 64
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.max, 64)
    }

    func testGetPrevHistoryUsesInjectedPageSize() {
        let manager = MessageArchiveManager(withOwner: owner)
        let queryId = manager.getPrevHistory(
            XMPPStream(),
            for: "romeo@example.com",
            conversationType: .regular,
            messageId: "newest-id",
            pageSize: 58
        )

        XCTAssertEqual(queuedTask(manager, queryId: queryId)?.max, 58)
    }

    func testEndPageCallbackFiresOnlyForMatchingQuery() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        var receivedQueryId: String?
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "matching end-page callback")

        _ = manager.getNextHistory(
            stream,
            for: "romeo@example.com",
            conversationType: .regular,
            messageId: nil,
            queryId: "query-1",
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { queryId, state, _, _, _ in
                    receivedQueryId = queryId
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )
        _ = manager.getNextHistory(
            stream,
            for: "romeo@example.com",
            conversationType: .regular,
            messageId: nil,
            queryId: "query-2",
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { queryId, _, _, _, _ in
                    XCTFail("Unexpected callback for \(queryId)")
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='query-1'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='query-1'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
              <first>first-id</first>
              <last>last-id</last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(receivedQueryId, "query-1")
        XCTAssertEqual(receivedState, .init(queryExhausted: true, archiveEnded: true, persistedMessageCount: 0, requestCursorId: nil))
    }

    func testMessageCallbackFiresOnlyForMatchingQuery() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        var received: [String] = []
        let callbackExpectation = expectation(description: "matching message callback")

        let matchingQuery = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "hello",
            max: 20,
            loadFull: false,
            requestCallbacks: .init(
                onMessage: { item, _ in
                    received.append(item.archivedId)
                    callbackExpectation.fulfill()
                },
                onEndPage: nil
            )
        )
        _ = manager.searchText(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            text: "hello",
            max: 20,
            loadFull: false,
            requestCallbacks: .init(
                onMessage: { item, _ in
                    received.append("unexpected-\(item.archivedId)")
                },
                onEndPage: nil
            )
        )

        let message = try makeMessage(xml: """
        <message to='\(owner)' from='\(owner)'>
          <result xmlns='urn:xmpp:mam:2' queryid='\(matchingQuery)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' to='\(owner)' from='romeo@example.com' type='chat' id='message-1'>
                <archived xmlns='urn:xmpp:mam:tmp' by='\(owner)' id='archived-1'/>
                <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='archived-1'/>
                <time xmlns='https://xabber.com/protocol/delivery' by='\(owner)' stamp='2026-03-31T10:00:00Z'/>
                <origin-id xmlns='urn:xmpp:sid:0' id='message-1'/>
                <body>Hello</body>
              </message>
              <delay xmlns='urn:xmpp:delay' from='example.com' stamp='2026-03-31T10:00:00Z'/>
            </forwarded>
          </result>
        </message>
        """)

        XCTAssertTrue(manager.readMessage(message))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(received, ["archived-1"])
    }

    func testEligibleCompleteResponseMarksArchiveEndedAndPersistsFullArchiveLoaded() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        try insertLastChat()
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "eligible completion state")

        _ = manager.getNextHistory(
            stream,
            for: "romeo@example.com",
            conversationType: .regular,
            messageId: nil,
            queryId: "eligible-complete",
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { _, state, _, _, _ in
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='eligible-complete'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='eligible-complete'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
              <first>first-id</first>
              <last>last-id</last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(receivedState, .init(queryExhausted: true, archiveEnded: true, persistedMessageCount: 0, requestCursorId: nil))
        XCTAssertTrue(try fullArchiveLoaded())
    }

    func testStartFilteredCompleteResponseDoesNotMarkArchiveEndedOrFullArchiveLoaded() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        try insertLastChat(jid: "omemo@example.com", conversationType: .omemo)
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "filtered completion state")

        manager.requestArchive(
            stream,
            jid: "omemo@example.com",
            isContinues: false,
            conversationType: .omemo,
            purpose: .bootstrap,
            queryId: "filtered-complete",
            start: Date(timeIntervalSince1970: 1234),
            nextPage: "",
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { _, state, _, _, _ in
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='filtered-complete'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='filtered-complete'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
              <first>first-id</first>
              <last>last-id</last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(receivedState, .init(queryExhausted: true, archiveEnded: false, persistedMessageCount: 0, requestCursorId: nil))
        XCTAssertFalse(try fullArchiveLoaded(jid: "omemo@example.com", conversationType: .omemo))
    }

    func testBeforeIdFilteredZeroCountResponseDoesNotMarkArchiveEndedOrFullArchiveLoaded() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        try insertLastChat()
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "zero-count filtered completion")

        manager.requestArchive(
            stream,
            jid: "romeo@example.com",
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: "filtered-zero-count",
            beforeId: "stanza-42",
            nextPage: "",
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { _, state, _, _, _ in
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='filtered-zero-count'>
          <fin xmlns='urn:xmpp:mam:2' complete='false' queryid='filtered-zero-count'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>0</count>
              <first></first>
              <last></last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(receivedState, .init(queryExhausted: true, archiveEnded: false, persistedMessageCount: 0, requestCursorId: nil))
        XCTAssertFalse(try fullArchiveLoaded())
    }

    func testConsumerManagedOlderPageDoesNotPersistArchiveEndOrTransportCursor() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        try insertLastChat(fullArchiveLoaded: false, lastLoadedMessageHistoryId: "persisted-oldest")
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "consumer managed older page completion")

        manager.requestArchive(
            stream,
            jid: "romeo@example.com",
            isContinues: false,
            conversationType: .regular,
            purpose: .pageOlder,
            queryId: "consumer-managed-page",
            nextPage: "requested-oldest",
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { _, state, _, _, _ in
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='consumer-managed-page'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='consumer-managed-page'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
              <first>transport-first</first>
              <last>transport-last</last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(
            receivedState,
            .init(queryExhausted: true, archiveEnded: true, persistedMessageCount: 0, requestCursorId: nil)
        )
        XCTAssertFalse(try fullArchiveLoaded())
        XCTAssertEqual(try persistedHistoryCursorId(), "persisted-oldest")
    }

    func testConsumerManagedNotificationRequestFiresEndPageCallbacksWithoutLastChatStorage() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "notification completion without last chat")

        manager.requestArchive(
            stream,
            jid: "notifications.example.com",
            isContinues: false,
            conversationType: .notifications,
            purpose: .latest,
            queryId: "notification-without-last-chat",
            flipPage: false,
            nextPage: "",
            max: 100,
            consumerManagesArchiveEnd: true,
            consumerManagesHistoryCursor: true,
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { _, state, _, _, _ in
                    receivedState = state
                    callbackExpectation.fulfill()
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='notification-without-last-chat'>
          <fin xmlns='urn:xmpp:mam:2' complete='true' queryid='notification-without-last-chat'>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
              <first>first-id</first>
              <last>last-id</last>
            </set>
          </fin>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation], timeout: 1.0)
        XCTAssertEqual(
            receivedState,
            .init(queryExhausted: true, archiveEnded: true, persistedMessageCount: 0, requestCursorId: nil)
        )
    }

    func testJumpErrorResultCompletesCallbackAndEndPageWithoutHanging() throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = XMPPStream()
        var receivedState: MessageArchivePageEndState?
        let callbackExpectation = expectation(description: "jump callback")
        let endPageExpectation = expectation(description: "jump end page")

        _ = manager.fetchAnchorMessage(
            stream,
            jid: "romeo@example.com",
            conversationType: .regular,
            archivedId: "archived-42",
            queryId: "jump-error",
            callback: {
                callbackExpectation.fulfill()
            },
            requestCallbacks: .init(
                onMessage: nil,
                onEndPage: { queryId, state, _, _, count in
                    XCTAssertEqual(queryId, "jump-error")
                    XCTAssertEqual(count, 0)
                    receivedState = state
                    endPageExpectation.fulfill()
                }
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='error' id='jump-error'>
          <error type='cancel'>
            <item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
          </error>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        wait(for: [callbackExpectation, endPageExpectation], timeout: 1.0)
        XCTAssertEqual(
            receivedState,
            .init(queryExhausted: true, archiveEnded: false, persistedMessageCount: 0, requestCursorId: nil)
        )
        XCTAssertTrue(manager.callbacksQueue.isEmpty)
    }
}

final class ChatHistoryPagingPolicyTests: XCTestCase {

    private func boundaryContext(
        firstRealSection: Int? = 0,
        lastRealSection: Int? = 9,
        visibleRealSections: [Int]
    ) -> ChatHistoryPagingBoundaryContext {
        ChatHistoryPagingBoundaryContext(
            firstRealSection: firstRealSection,
            lastRealSection: lastRealSection,
            visibleRealSections: visibleRealSections
        )
    }

    func testOlderPagingTriggersWhenOldestVisibleSectionIsReachedWhileScrollingOlder() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: 48,
                boundaryContext: boundaryContext(visibleRealSections: [6, 7, 8, 9]),
                currentPageMinIndex: 0
            ),
            .older
        )
    }

    func testNewerPagingTriggersWhenNewestVisibleSectionIsReachedWhileScrollingNewer() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: -32,
                boundaryContext: boundaryContext(visibleRealSections: [0, 1, 2]),
                currentPageMinIndex: 100
            ),
            .newer
        )
    }

    func testPagingDoesNotTriggerAwayFromVisibleBoundary() {
        XCTAssertNil(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: 44,
                boundaryContext: boundaryContext(visibleRealSections: [2, 3, 4]),
                currentPageMinIndex: 0
            )
        )
    }

    func testPagingDoesNotTriggerAfterGestureStopsEvenIfBoundaryIsVisible() {
        XCTAssertNil(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: false,
                canLoadDatasource: true,
                gestureTranslationY: 44,
                boundaryContext: boundaryContext(visibleRealSections: [6, 7, 8, 9]),
                currentPageMinIndex: 0
            )
        )
    }

    func testOlderPagingTriggersWhenOlderBoundaryIsTheOnlyAvailableDirection() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: -44,
                boundaryContext: boundaryContext(visibleRealSections: [6, 7, 8, 9]),
                currentPageMinIndex: 0
            ),
            .older
        )
    }

    func testOlderPagingTriggersWhenLastVisibleRealMessageReachesBoundaryEvenWithTrailingFakeSection() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: 32,
                boundaryContext: boundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 8,
                    visibleRealSections: [6, 7, 8]
                ),
                currentPageMinIndex: 0
            ),
            .older
        )
    }

    func testPagingDoesNotTriggerWhenOnlyFakeSectionsAreVisible() {
        XCTAssertNil(
            ChatHistoryPagingPolicy.triggerDirection(
                isUserScrolling: true,
                canLoadDatasource: true,
                gestureTranslationY: 32,
                boundaryContext: boundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 8,
                    visibleRealSections: []
                ),
                currentPageMinIndex: 0
            )
        )
    }

    func testRequestedOlderWindowCanRunPastLocalObserverWithoutBeingClamped() {
        let coordinator = ChatDatasetCoordinator(pageSize: 100)

        XCTAssertEqual(
            coordinator.nextWindow(
                from: ChatDatasetWindow(minIndex: 0, maxIndex: 50),
                direction: .older
            ),
            ChatDatasetWindow(minIndex: 0, maxIndex: 150)
        )
    }

    func testOlderPagingRequestsRemoteArchiveWhenLocalHistoryIsExhausted() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.loadDecision(
                direction: .older,
                currentWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 50),
                requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 150),
                localWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 50),
                totalCount: 50,
                isArchiveEnded: false
            ),
            .remoteOlderPage
        )
    }

    func testOlderPagingStopsCleanlyWhenArchiveEndWasAlreadyReached() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.loadDecision(
                direction: .older,
                currentWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 50),
                requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 150),
                localWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 50),
                totalCount: 50,
                isArchiveEnded: true
            ),
            .endReached
        )
    }

    func testOlderPagingUsesRemainingLocalMessagesBeforeRemoteArchive() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.loadDecision(
                direction: .older,
                currentWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 100),
                requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 200),
                localWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 150),
                totalCount: 150,
                isArchiveEnded: false
            ),
            .remoteOlderPage
        )
    }

    func testOlderPagingDoesNotSplitLocalRemainderAndRemotePageIntoSeparateInteractions() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.loadDecision(
                direction: .older,
                currentWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 100),
                requestedWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 200),
                localWindow: ChatDatasetWindow(minIndex: 0, maxIndex: 120),
                totalCount: 120,
                isArchiveEnded: false
            ),
            .remoteOlderPage
        )
    }

    func testShortContentDragFallbackRequestsOlderPageWhenOldestBoundaryIsVisible() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.fallbackDirectionForShortContentDrag(
                canLoadDatasource: true,
                gestureTranslationY: 52,
                boundaryContext: boundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 6,
                    visibleRealSections: [4, 5, 6]
                ),
                currentPageMinIndex: 0
            ),
            .older
        )
    }

    func testShortContentDragFallbackUsesLastVisibleRealMessageWhenDatasourceEndsWithFakeSection() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.fallbackDirectionForShortContentDrag(
                canLoadDatasource: true,
                gestureTranslationY: 52,
                boundaryContext: boundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 5,
                    visibleRealSections: [4, 5]
                ),
                currentPageMinIndex: 0
            ),
            .older
        )
    }

    func testShortContentDragFallbackUsesOnlyAvailableOlderBoundaryRegardlessOfGestureSign() {
        XCTAssertEqual(
            ChatHistoryPagingPolicy.fallbackDirectionForShortContentDrag(
                canLoadDatasource: true,
                gestureTranslationY: -52,
                boundaryContext: boundaryContext(
                    firstRealSection: 0,
                    lastRealSection: 6,
                    visibleRealSections: [4, 5, 6]
                ),
                currentPageMinIndex: 0
            ),
            .older
        )
    }
}

final class ChatArchiveEndVerificationPolicyTests: XCTestCase {

    func testPersistedArchiveEndIsProbedOncePerSessionUntilConfirmed() {
        XCTAssertTrue(
            ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
                persistedArchiveEnded: true,
                hasConfirmedArchiveEndThisSession: false,
                hasUsedVerificationProbe: false
            )
        )
    }

    func testPersistedArchiveEndIsTrustedAfterSessionConfirmation() {
        XCTAssertFalse(
            ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
                persistedArchiveEnded: true,
                hasConfirmedArchiveEndThisSession: true,
                hasUsedVerificationProbe: false
            )
        )
    }

    func testPersistedArchiveEndIsNotProbedAgainAfterVerificationAttempt() {
        XCTAssertFalse(
            ChatArchiveEndVerificationPolicy.shouldProbePersistedArchiveEnd(
                persistedArchiveEnded: true,
                hasConfirmedArchiveEndThisSession: false,
                hasUsedVerificationProbe: true
            )
        )
    }

    func testEffectiveArchiveEndIgnoresPersistedFlagDuringVerificationProbe() {
        XCTAssertFalse(
            ChatArchiveEndVerificationPolicy.effectiveArchiveEnded(
                persistedArchiveEnded: true,
                shouldProbePersistedArchiveEnd: true
            )
        )
    }

    func testEffectiveArchiveEndKeepsPersistedFlagWhenNoProbeIsNeeded() {
        XCTAssertTrue(
            ChatArchiveEndVerificationPolicy.effectiveArchiveEnded(
                persistedArchiveEnded: true,
                shouldProbePersistedArchiveEnd: false
            )
        )
    }
}

final class ChatHistoryCursorSelectionPolicyTests: XCTestCase {

    func testOldestCursorUsesLastObservedArchivedIdWhenTailMessagesHaveArchiveIds() {
        XCTAssertEqual(
            ChatHistoryCursorSelectionPolicy.oldestCursorId(
                observedArchivedIds: ["newest-1", "middle-1", "oldest-1"],
                persistedCursorId: "persisted-oldest"
            ),
            "oldest-1"
        )
    }

    func testOldestCursorSkipsTailMessagesWithoutArchiveIds() {
        XCTAssertEqual(
            ChatHistoryCursorSelectionPolicy.oldestCursorId(
                observedArchivedIds: ["newest-1", "oldest-with-archive", "", ""],
                persistedCursorId: "persisted-oldest"
            ),
            "oldest-with-archive"
        )
    }

    func testOldestCursorFallsBackToPersistedHistoryCursorWhenObservedMessagesHaveNoArchiveIds() {
        XCTAssertEqual(
            ChatHistoryCursorSelectionPolicy.oldestCursorId(
                observedArchivedIds: ["", "", ""],
                persistedCursorId: "persisted-oldest"
            ),
            "persisted-oldest"
        )
    }

    func testOldestCursorReturnsNilWhenNoObservedOrPersistedCursorExists() {
        XCTAssertNil(
            ChatHistoryCursorSelectionPolicy.oldestCursorId(
                observedArchivedIds: ["", ""],
                persistedCursorId: nil
            )
        )
    }
}

final class ChatObserverLookupPolicyTests: XCTestCase {

    private func makeMessage(primary: String, archivedId: String) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = primary
        message.archivedId = archivedId
        return message
    }

    func testObserverLookupBuildCapturesOldestArchivedIdDuringSinglePass() {
        let lookup = ChatObserverLookupPolicy.build(
            from: [
                makeMessage(primary: "primary-1", archivedId: "archived-3"),
                makeMessage(primary: "primary-2", archivedId: ""),
                makeMessage(primary: "primary-3", archivedId: "archived-2"),
                makeMessage(primary: "primary-4", archivedId: "archived-1")
            ]
        )

        XCTAssertEqual(lookup.primaryIndex["primary-2"], 1)
        XCTAssertEqual(lookup.archivedIdIndex["archived-1"], 3)
        XCTAssertEqual(lookup.oldestArchivedId, "archived-1")
    }
}

final class ChatMessageAnchorPolicyTests: XCTestCase {

    private func makeRequest(
        archivedId: String? = "archived-42",
        messageId: String? = "message-42",
        sourceDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(
            chatJid: "group@xabber.example",
            owner: "owner@example.com",
            conversationType: .group,
            anchor: ChatMessageAnchorRef(
                messagePrimary: nil,
                archivedId: archivedId,
                messageId: messageId,
                authorId: "author-1",
                bodyFingerprint: "hello @you",
                sourceDate: sourceDate
            ),
            highlight: false,
            markReadOnVisible: false,
            source: .mentionNotification
        )
    }

    func testAnchorFetchPolicyPrefersExactArchivedIdWhenAvailable() {
        let anchor = ChatMessageAnchorRef(
            messagePrimary: nil,
            archivedId: "archived-42",
            messageId: "message-42",
            authorId: "author-1",
            bodyFingerprint: "hello @you",
            sourceDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(
            ChatAnchorFetchPolicy.initialPlan(for: anchor, pageSize: ChatHistoryPagingConfiguration.pageSize),
            .exactArchivedId("archived-42")
        )
    }

    func testAnchorFetchPolicyFallsBackToBoundedDateWindowAfterExactArchivedIdMiss() {
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let anchor = ChatMessageAnchorRef(
            messagePrimary: nil,
            archivedId: "archived-42",
            messageId: "message-42",
            authorId: "author-1",
            bodyFingerprint: "hello @you",
            sourceDate: sourceDate
        )

        let fallback = ChatAnchorFetchPolicy.fallbackPlan(
            after: .exactArchivedId("archived-42"),
            anchor: anchor,
            pageSize: ChatHistoryPagingConfiguration.pageSize
        )

        XCTAssertEqual(
            fallback,
            .dateWindow(
                start: sourceDate.addingTimeInterval(-60),
                end: sourceDate.addingTimeInterval(60),
                max: ChatHistoryPagingConfiguration.pageSize
            )
        )
    }

    func testAnchorFetchPolicyUsesDateWindowWhenArchivedIdIsMissing() {
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_100)
        let anchor = ChatMessageAnchorRef(
            messagePrimary: nil,
            archivedId: nil,
            messageId: "message-42",
            authorId: "author-1",
            bodyFingerprint: "hello @you",
            sourceDate: sourceDate
        )

        XCTAssertEqual(
            ChatAnchorFetchPolicy.initialPlan(for: anchor, pageSize: 40),
            .dateWindow(
                start: sourceDate.addingTimeInterval(-60),
                end: sourceDate.addingTimeInterval(60),
                max: 40
            )
        )
    }

    func testAnchorContextPrefetchSkipsRemoteLoadsWhenLocalContextIsSufficient() {
        let plan = ChatAnchorContextPrefetchPolicy.plan(
            observerIndex: 60,
            totalCount: 150,
            pageSize: ChatHistoryPagingConfiguration.pageSize,
            archivedId: "archived-42"
        )

        XCTAssertEqual(plan, ChatAnchorContextPrefetchPlan(newerPageSize: nil, olderPageSize: nil))
        XCTAssertFalse(plan.requiresRemoteFetch)
    }

    func testAnchorContextPrefetchRequestsMissingNewerAndOlderContext() {
        let plan = ChatAnchorContextPrefetchPolicy.plan(
            observerIndex: 5,
            totalCount: 20,
            pageSize: ChatHistoryPagingConfiguration.pageSize,
            archivedId: "archived-42"
        )

        XCTAssertEqual(plan.newerPageSize, 45)
        XCTAssertEqual(plan.olderPageSize, 36)
        XCTAssertTrue(plan.requiresRemoteFetch)
    }

    func testAnchorContextPrefetchSkipsRemoteLoadsWithoutArchivedId() {
        let plan = ChatAnchorContextPrefetchPolicy.plan(
            observerIndex: 1,
            totalCount: 3,
            pageSize: ChatHistoryPagingConfiguration.pageSize,
            archivedId: nil
        )

        XCTAssertEqual(plan, ChatAnchorContextPrefetchPlan(newerPageSize: nil, olderPageSize: nil))
    }

    func testAnchorContextPrefetchCompletionWaitsWhileQueriesRemain() {
        XCTAssertEqual(
            ChatAnchorContextPrefetchPolicy.completionAction(
                pendingQueryIds: ["q1"],
                totalPersistedMessageCount: 2
            ),
            .waitForMoreQueries
        )
    }

    func testAnchorContextPrefetchCompletionWaitsForObserverSyncAfterPersistedResults() {
        XCTAssertEqual(
            ChatAnchorContextPrefetchPolicy.completionAction(
                pendingQueryIds: [],
                totalPersistedMessageCount: 2
            ),
            .waitForObserverSync
        )
    }

    func testAnchorContextPrefetchCompletionFinishesWhenNoResultsPersisted() {
        XCTAssertEqual(
            ChatAnchorContextPrefetchPolicy.completionAction(
                pendingQueryIds: [],
                totalPersistedMessageCount: 0
            ),
            .complete
        )
    }

    func testAnchorContextPrefetchResumeWaitsForOutstandingQueries() {
        XCTAssertEqual(
            ChatAnchorContextPrefetchPolicy.resumeAction(
                pendingQueryIds: ["q1"],
                totalPersistedMessageCount: 2,
                areMessagePipelinesIdle: true,
                didObservePostIdleTick: false
            ),
            .waitForOutstandingQueries
        )
    }

    func testAnchorContextPrefetchResumeWaitsForPendingPersistence() {
        XCTAssertEqual(
            ChatAnchorContextPrefetchPolicy.resumeAction(
                pendingQueryIds: [],
                totalPersistedMessageCount: 2,
                areMessagePipelinesIdle: false,
                didObservePostIdleTick: false
            ),
            .waitForPendingMessagePersistence
        )
    }

    func testAnchorContextPrefetchResumeWaitsForObserverSettleAfterPersistence() {
        XCTAssertEqual(
            ChatAnchorContextPrefetchPolicy.resumeAction(
                pendingQueryIds: [],
                totalPersistedMessageCount: 2,
                areMessagePipelinesIdle: true,
                didObservePostIdleTick: false
            ),
            .waitForObserverSettle
        )
    }

    func testAnchorContextPrefetchResumeBecomesReadyAfterObserverSettle() {
        XCTAssertEqual(
            ChatAnchorContextPrefetchPolicy.resumeAction(
                pendingQueryIds: [],
                totalPersistedMessageCount: 2,
                areMessagePipelinesIdle: true,
                didObservePostIdleTick: true
            ),
            .readyToPosition
        )
    }

    func testAnchorContextPrefetchResumeIsImmediatelyReadyWhenNothingPersisted() {
        XCTAssertEqual(
            ChatAnchorContextPrefetchPolicy.resumeAction(
                pendingQueryIds: [],
                totalPersistedMessageCount: 0,
                areMessagePipelinesIdle: false,
                didObservePostIdleTick: false
            ),
            .readyToPosition
        )
    }

    func testInitialScrollPolicyDefersDefaultScrollForPendingOrActiveAnchorNavigation() {
        XCTAssertTrue(
            ChatInitialScrollPolicy.shouldDeferDefaultScroll(
                hasPendingAnchorRequest: true,
                isAnchorNavigationInFlight: false
            )
        )
        XCTAssertTrue(
            ChatInitialScrollPolicy.shouldDeferDefaultScroll(
                hasPendingAnchorRequest: false,
                isAnchorNavigationInFlight: true
            )
        )
        XCTAssertFalse(
            ChatInitialScrollPolicy.shouldDeferDefaultScroll(
                hasPendingAnchorRequest: false,
                isAnchorNavigationInFlight: false
            )
        )
    }

    func testAnchorLoadingPresentationUsesSkeletonDuringInitialBootstrapNavigation() {
        XCTAssertEqual(
            ChatAnchorLoadingPresentationPolicy.presentation(isBootstrapNavigation: true),
            .skeleton
        )
        XCTAssertEqual(
            ChatAnchorLoadingPresentationPolicy.presentation(isBootstrapNavigation: false),
            .activityIndicator
        )
    }

    func testAnchorExecutionPolicyWaitsForObserverRefreshAfterPersistedRemoteResults() {
        let request = makeRequest()
        let state = ChatAnchorExecutionState(request: request)

        XCTAssertEqual(
            ChatAnchorExecutionPolicy.remoteCompletionAction(
                state: state,
                hasLocalMatch: false,
                persistedMessageCount: 1,
                remoteResultCount: 0,
                pageSize: ChatHistoryPagingConfiguration.pageSize
            ),
            .waitForObserverSync
        )
    }

    func testAnchorExecutionPolicyWaitsForObserverRefreshAfterNonEmptyRemoteResultWithoutPersistedCount() {
        let request = makeRequest()
        let state = ChatAnchorExecutionState(request: request)

        XCTAssertEqual(
            ChatAnchorExecutionPolicy.remoteCompletionAction(
                state: state,
                hasLocalMatch: false,
                persistedMessageCount: 0,
                remoteResultCount: 101,
                pageSize: ChatHistoryPagingConfiguration.pageSize
            ),
            .waitForObserverSync
        )
    }

    func testAnchorExecutionPolicyWaitsForObserverRefreshAfterDateWindowReturnsMessages() {
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        var state = ChatAnchorExecutionState(
            request: makeRequest(sourceDate: sourceDate)
        )
        state.lastAttemptedRemotePlan = .dateWindow(
            start: sourceDate.addingTimeInterval(-60),
            end: sourceDate.addingTimeInterval(60),
            max: ChatHistoryPagingConfiguration.pageSize
        )

        XCTAssertEqual(
            ChatAnchorExecutionPolicy.remoteCompletionAction(
                state: state,
                hasLocalMatch: false,
                persistedMessageCount: 0,
                remoteResultCount: 100,
                pageSize: ChatHistoryPagingConfiguration.pageSize
            ),
            .waitForObserverSync
        )
    }

    func testAnchorExecutionPolicyWaitsAfterExactMissThenNonEmptyDateWindowResult() {
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        var state = ChatAnchorExecutionState(
            request: makeRequest(sourceDate: sourceDate)
        )
        state.lastAttemptedRemotePlan = .exactArchivedId("archived-42")

        XCTAssertEqual(
            ChatAnchorExecutionPolicy.remoteCompletionAction(
                state: state,
                hasLocalMatch: false,
                persistedMessageCount: 0,
                remoteResultCount: 0,
                pageSize: ChatHistoryPagingConfiguration.pageSize
            ),
            .startRemoteFetch(
                .dateWindow(
                    start: sourceDate.addingTimeInterval(-60),
                    end: sourceDate.addingTimeInterval(60),
                    max: ChatHistoryPagingConfiguration.pageSize
                )
            )
        )

        state.lastAttemptedRemotePlan = .dateWindow(
            start: sourceDate.addingTimeInterval(-60),
            end: sourceDate.addingTimeInterval(60),
            max: ChatHistoryPagingConfiguration.pageSize
        )

        XCTAssertEqual(
            ChatAnchorExecutionPolicy.remoteCompletionAction(
                state: state,
                hasLocalMatch: false,
                persistedMessageCount: 0,
                remoteResultCount: 100,
                pageSize: ChatHistoryPagingConfiguration.pageSize
            ),
            .waitForObserverSync
        )
    }

    func testAnchorFailureRecoveryReappliesBootstrapStateEvenWithFailureHook() {
        XCTAssertTrue(
            ChatAnchorFailureRecoveryPolicy.shouldReapplyBootstrapState(usesBootstrapLoading: true)
        )
        XCTAssertFalse(
            ChatAnchorFailureRecoveryPolicy.shouldRunDefaultFailurePresentation(
                usesBootstrapLoading: true,
                hasFailureHook: true
            )
        )
        XCTAssertEqual(
            ChatBootstrapViewState.resolve(
                messageCount: 1,
                isSynced: false,
                isInitialBootstrapInFlight: false,
                hasPendingInitialAnchorRequest: false
            ),
            .content
        )
    }

    func testAnchorExecutionPolicyKeepsWaitingDuringManualResumeUntilObserverRefreshArrives() {
        var state = ChatAnchorExecutionState(request: makeRequest())
        state.lastAttemptedRemotePlan = .exactArchivedId("archived-42")
        state.isWaitingForObserverSync = true

        XCTAssertEqual(
            ChatAnchorExecutionPolicy.resumeAction(
                state: state,
                hasLocalMatch: false,
                trigger: .manual,
                pageSize: ChatHistoryPagingConfiguration.pageSize
            ),
            .waitForObserverSync
        )
    }

    func testAnchorExecutionPolicyResolvesLocallyWhenObserverRefreshMakesAnchorVisible() {
        var state = ChatAnchorExecutionState(request: makeRequest())
        state.lastAttemptedRemotePlan = .exactArchivedId("archived-42")
        state.isWaitingForObserverSync = true

        XCTAssertEqual(
            ChatAnchorExecutionPolicy.resumeAction(
                state: state,
                hasLocalMatch: true,
                trigger: .observerRefresh,
                pageSize: ChatHistoryPagingConfiguration.pageSize
            ),
            .resolveLocally
        )
    }

    func testAnchorExecutionPolicyFallsBackAfterObserverRefreshWhenExactFetchStillMisses() {
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        var state = ChatAnchorExecutionState(
            request: makeRequest(sourceDate: sourceDate)
        )
        state.lastAttemptedRemotePlan = .exactArchivedId("archived-42")
        state.isWaitingForObserverSync = true

        XCTAssertEqual(
            ChatAnchorExecutionPolicy.resumeAction(
                state: state,
                hasLocalMatch: false,
                trigger: .observerRefresh,
                pageSize: ChatHistoryPagingConfiguration.pageSize
            ),
            .startRemoteFetch(
                .dateWindow(
                    start: sourceDate.addingTimeInterval(-60),
                    end: sourceDate.addingTimeInterval(60),
                    max: ChatHistoryPagingConfiguration.pageSize
                )
            )
        )
    }

    func testAnchorExecutionPolicyFailsAfterObserverRefreshWhenNoFurtherFallbackExists() {
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        var state = ChatAnchorExecutionState(
            request: makeRequest(archivedId: nil, messageId: "message-42", sourceDate: sourceDate)
        )
        state.lastAttemptedRemotePlan = .dateWindow(
            start: sourceDate.addingTimeInterval(-60),
            end: sourceDate.addingTimeInterval(60),
            max: ChatHistoryPagingConfiguration.pageSize
        )
        state.isWaitingForObserverSync = true

        XCTAssertEqual(
            ChatAnchorExecutionPolicy.resumeAction(
                state: state,
                hasLocalMatch: false,
                trigger: .observerRefresh,
                pageSize: ChatHistoryPagingConfiguration.pageSize
            ),
            .fail
        )
    }
}

final class ChatArchiveStateMutationPolicyTests: XCTestCase {

    func testMutationPlanSkipsWriteWhenCursorAndArchiveStateAreUnchanged() {
        let snapshot = ChatArchiveStateSnapshot(
            primaryKey: "chat-primary",
            persistedCursorId: "cursor-1",
            fullArchiveLoaded: false
        )
        let resolvedCursorId = ChatArchiveStateMutationPolicy.resolveCursorId(
            observedCursorId: nil,
            transportFirst: "",
            transportLast: "",
            currentPersistedCursorId: snapshot.persistedCursorId
        )
        let plan = ChatArchiveStateMutationPolicy.resolvePlan(
            snapshot: snapshot,
            resolvedCursorId: resolvedCursorId,
            nextFullArchiveLoaded: false
        )

        XCTAssertEqual(resolvedCursorId, "cursor-1")
        XCTAssertFalse(plan.shouldWriteCursor)
        XCTAssertFalse(plan.shouldWriteFullArchiveLoaded)
        XCTAssertFalse(plan.needsWrite)
    }

    func testMutationPlanWritesCursorAndArchiveStateTogetherWhenBothChange() {
        let snapshot = ChatArchiveStateSnapshot(
            primaryKey: "chat-primary",
            persistedCursorId: nil,
            fullArchiveLoaded: false
        )
        let resolvedCursorId = ChatArchiveStateMutationPolicy.resolveCursorId(
            observedCursorId: "cursor-2",
            transportFirst: "",
            transportLast: "",
            currentPersistedCursorId: snapshot.persistedCursorId
        )
        let plan = ChatArchiveStateMutationPolicy.resolvePlan(
            snapshot: snapshot,
            resolvedCursorId: resolvedCursorId,
            nextFullArchiveLoaded: true
        )

        XCTAssertEqual(resolvedCursorId, "cursor-2")
        XCTAssertTrue(plan.shouldWriteCursor)
        XCTAssertTrue(plan.shouldWriteFullArchiveLoaded)
        XCTAssertTrue(plan.needsWrite)
    }
}

final class ChatHistoryPageOutcomePolicyTests: XCTestCase {

    func testOlderPageAdvancedWhenPersistedBoundaryMoves() {
        XCTAssertEqual(
            ChatHistoryPageOutcomePolicy.resolve(
                queryExhausted: false,
                didAdvance: true,
                persistedMessageCount: 100,
                requestedCursorId: "cursor-1",
                currentCursorId: "cursor-2"
            ),
            .advanced(persistedCursorId: "cursor-2")
        )
    }

    func testOlderPageMarksArchiveEndOnlyWhenQueryExhaustedAndBoundaryDidNotMove() {
        XCTAssertEqual(
            ChatHistoryPageOutcomePolicy.resolve(
                queryExhausted: true,
                didAdvance: false,
                persistedMessageCount: 0,
                requestedCursorId: "cursor-1",
                currentCursorId: "cursor-1"
            ),
            .emptyExhausted(persistedCursorId: "cursor-1")
        )
    }

    func testOlderPageTreatsNonAdvancingPersistedMessagesAsDuplicateInsteadOfArchiveEnd() {
        XCTAssertEqual(
            ChatHistoryPageOutcomePolicy.resolve(
                queryExhausted: true,
                didAdvance: false,
                persistedMessageCount: 3,
                requestedCursorId: "cursor-1",
                currentCursorId: "cursor-1"
            ),
            .duplicateOrNoAdvance(persistedCursorId: "cursor-1")
        )
    }
}

final class ChatHistoryPageCompletionPolicyTests: XCTestCase {

    func testInteractiveHistoryPageCompletionWaitsWhenObserverAdvancesBeforeFin() {
        XCTAssertFalse(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: false,
                didAdvance: true,
                persistedMessageCount: 1,
                isMessagePipelineIdle: true
            )
        )
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: true,
                persistedMessageCount: 1,
                isMessagePipelineIdle: true
            )
        )
    }

    func testInteractiveHistoryPageCompletionWaitsWhenFinArrivesBeforeObserverAdvance() {
        XCTAssertFalse(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: false,
                persistedMessageCount: 3,
                isMessagePipelineIdle: true
            )
        )
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: true,
                persistedMessageCount: 3,
                isMessagePipelineIdle: true
            )
        )
    }

    func testInteractiveHistoryPageCompletionFinishesImmediatelyWhenServerPagePersistsNoMessages() {
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: false,
                persistedMessageCount: 0,
                isMessagePipelineIdle: true
            )
        )
    }

    func testInteractiveHistoryPageCompletionWaitsUntilMessagePipelineIsIdle() {
        XCTAssertFalse(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: true,
                persistedMessageCount: 10,
                isMessagePipelineIdle: false
            )
        )
    }

    func testInteractiveHistoryPageCompletionWaitsForObserverSettleAfterPipelineBecomesIdle() {
        XCTAssertFalse(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: true,
                persistedMessageCount: 10,
                isMessagePipelineIdle: true,
                requiresObserverSettle: true,
                didObservePostIdleTick: false
            )
        )
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: true,
                persistedMessageCount: 10,
                isMessagePipelineIdle: true,
                requiresObserverSettle: true,
                didObservePostIdleTick: true
            )
        )
    }

    func testInteractiveHistoryPageCompletionDoesNotRequireObserverSettleForEmptyPage() {
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.shouldFinish(
                didReceiveEndPage: true,
                didAdvance: false,
                persistedMessageCount: 0,
                isMessagePipelineIdle: true,
                requiresObserverSettle: false,
                didObservePostIdleTick: false
            )
        )
    }

    func testOlderPageCompletionAdvancesWhenObserverCountGrows() {
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.didAdvance(
                previousObserverCount: 100,
                currentObserverCount: 180,
                previousOldestArchivedId: "100",
                currentOldestArchivedId: "100",
                previousArchiveEnded: false,
                currentArchiveEnded: false
            )
        )
    }

    func testOlderPageCompletionAdvancesWhenOldestArchivedIdChangesWithoutCountGrowth() {
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.didAdvance(
                previousObserverCount: 100,
                currentObserverCount: 100,
                previousOldestArchivedId: "1771925790869010",
                currentOldestArchivedId: "1770722527493600",
                previousArchiveEnded: false,
                currentArchiveEnded: false
            )
        )
    }

    func testOlderPageCompletionAdvancesWhenArchiveEndBecomesKnown() {
        XCTAssertTrue(
            ChatHistoryPageCompletionPolicy.didAdvance(
                previousObserverCount: 100,
                currentObserverCount: 100,
                previousOldestArchivedId: "1771925790869010",
                currentOldestArchivedId: "1771925790869010",
                previousArchiveEnded: false,
                currentArchiveEnded: true
            )
        )
    }

    func testOlderPageCompletionWaitsWhenFinArrivesBeforeObserverStateChanges() {
        XCTAssertFalse(
            ChatHistoryPageCompletionPolicy.didAdvance(
                previousObserverCount: 100,
                currentObserverCount: 100,
                previousOldestArchivedId: "1771925790869010",
                currentOldestArchivedId: "1771925790869010",
                previousArchiveEnded: false,
                currentArchiveEnded: false
            )
        )
    }
}

final class ChatHistoryPageApplyPolicyTests: XCTestCase {

    func testOlderPagingDoesNotKeepOffsetInInvertedTimeline() {
        XCTAssertFalse(ChatHistoryPageApplyPolicy.keepOffset(direction: .older))
    }

    func testNewerPagingKeepsOffsetInInvertedTimeline() {
        XCTAssertTrue(ChatHistoryPageApplyPolicy.keepOffset(direction: .newer))
    }
}

final class ChatHistoryPageAnchorRestorePolicyTests: XCTestCase {

    func testAnchorRestoreUsesCapturedViewportOffset() {
        XCTAssertEqual(
            ChatHistoryPageAnchorRestorePolicy.targetContentOffsetY(
                anchorMinY: 420,
                offsetFromViewportTop: 120,
                minContentOffsetY: 0,
                maxContentOffsetY: 800
            ),
            300
        )
    }

    func testAnchorRestoreClampsToScrollableBounds() {
        XCTAssertEqual(
            ChatHistoryPageAnchorRestorePolicy.targetContentOffsetY(
                anchorMinY: 40,
                offsetFromViewportTop: 120,
                minContentOffsetY: -16,
                maxContentOffsetY: 200
            ),
            -16
        )
    }
}

final class ChatHistoryLoadingTimeoutPolicyTests: XCTestCase {

    func testInteractivePageLoadDoesNotAbortAtSoftTimeout() {
        XCTAssertFalse(
            ChatHistoryLoadingTimeoutPolicy.shouldAbortInteractivePageLoad(
                elapsed: ChatHistoryLoadingTimeoutPolicy.checkInterval
            )
        )
    }

    func testInteractivePageLoadAbortsAtHardTimeout() {
        XCTAssertTrue(
            ChatHistoryLoadingTimeoutPolicy.shouldAbortInteractivePageLoad(
                elapsed: ChatHistoryLoadingTimeoutPolicy.interactiveHardTimeout
            )
        )
    }
}

final class ChatDatasourceApplyGenerationPolicyTests: XCTestCase {

    func testSupersededGenerationDoesNotApply() {
        XCTAssertFalse(
            ChatDatasourceApplyGenerationPolicy.shouldApply(
                requestGeneration: 3,
                currentGeneration: 4
            )
        )
    }

    func testCurrentGenerationApplies() {
        XCTAssertTrue(
            ChatDatasourceApplyGenerationPolicy.shouldApply(
                requestGeneration: 4,
                currentGeneration: 4
            )
        )
    }
}

final class MessageManagerQueueSynchronizationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "MessageManagerQueueSynchronizationTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "MessageManagerQueueSynchronizationTests", code: 1)
        }
        return root
    }

    private func makeMessage(index: Int) throws -> XMPPMessage {
        try XMPPMessage(from: makeElement(xml: """
        <message from='romeo@example.com' to='owner@example.com' type='chat' id='message-\(index)'>
          <origin-id xmlns='urn:xmpp:sid:0' id='message-\(index)'/>
          <body>\(index)</body>
        </message>
        """))
    }

    private func makeQueueItem(index: Int) throws -> MessageManager.MessageQueueItem {
        MessageManager.MessageQueueItem(
            try makeMessage(index: index),
            messageId: "message-\(index)",
            archivedFrom: "romeo@example.com",
            isRead: false,
            date: Date(timeIntervalSince1970: TimeInterval(index)),
            state: .deliver,
            queryId: "query-\(index)"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.02,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    func testConcurrentEnqueueKeepsEveryUniqueMessageInSerializedBuffer() throws {
        let manager = MessageManager(withOwner: "owner@example.com", activeStream: false)
        manager.unsubscribeReceiver()

        let group = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "MessageManagerQueueSynchronizationTests.enqueue", attributes: .concurrent)

        for index in 0..<100 {
            group.enter()
            concurrentQueue.async {
                defer { group.leave() }
                if let item = try? self.makeQueueItem(index: index) {
                    manager.enqueue(item)
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let snapshot = manager.performMessageQueueSync { manager.queuedMessages }
        XCTAssertEqual(snapshot.count, 100)
        XCTAssertEqual(Set(snapshot.compactMap(\.messageId)).count, 100)
        XCTAssertEqual(manager.messagesQueue.value.count, 100)
    }

    func testEnqueueSchedulesAutomaticDrainWithoutManualFlush() throws {
        let manager = MessageManager(withOwner: "owner@example.com", activeStream: false)
        manager.clearQueue()

        let item = try makeQueueItem(index: 1)
        manager.enqueue(item)

        XCTAssertTrue(
            waitUntil {
                manager.performMessageQueueSync {
                    manager.queuedMessages.isEmpty &&
                    !manager.hasPendingMessages(forQueryId: "query-1")
                }
            }
        )
        XCTAssertTrue(manager.messagesQueue.value.isEmpty)
        XCTAssertFalse(manager.performMessageQueueSync { manager.isQueuedMessagesDrainScheduled })
    }
}

final class ChatMarkersCleanupSchedulingTests: XCTestCase {

    private final class SpyChatMarkersManager: ChatMarkersManager {
        private let lock = NSLock()
        private var runCountStorage = 0
        private var activeRunsStorage = 0
        private var maxConcurrentRunsStorage = 0

        var onRun: (() -> Void)?
        var gate: DispatchSemaphore?

        init(owner: String) {
            super.init(withOwner: owner, withoutAfterburnTimer: true)
        }

        override func runEphemeralCleanup() {
            self.lock.lock()
            self.runCountStorage += 1
            self.activeRunsStorage += 1
            self.maxConcurrentRunsStorage = max(self.maxConcurrentRunsStorage, self.activeRunsStorage)
            let callback = self.onRun
            self.lock.unlock()

            callback?()
            if let gate = self.gate {
                _ = gate.wait(timeout: .now() + 2)
            }

            self.lock.lock()
            self.activeRunsStorage -= 1
            self.lock.unlock()
        }

        var runCount: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.runCountStorage
        }

        var activeRuns: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.activeRunsStorage
        }

        var maxConcurrentRuns: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.maxConcurrentRunsStorage
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.02,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    func testRapidTriggersCoalesceIntoSingleFollowupPassWithoutOverlap() {
        let manager = SpyChatMarkersManager(owner: "owner@example.com")
        let firstRunStarted = expectation(description: "first run started")
        let secondRunStarted = expectation(description: "second run started")
        let gate = DispatchSemaphore(value: 0)
        manager.gate = gate

        manager.onRun = {
            let runCount = manager.runCount
            if runCount == 1 {
                firstRunStarted.fulfill()
            } else if runCount == 2 {
                secondRunStarted.fulfill()
            }
        }

        manager.deleteEphemeralMessages()
        wait(for: [firstRunStarted], timeout: 1)

        for _ in 0..<30 {
            manager.deleteEphemeralMessages()
        }

        gate.signal()
        wait(for: [secondRunStarted], timeout: 1)
        gate.signal()

        XCTAssertTrue(
            waitUntil {
                manager.runCount == 2 && manager.activeRuns == 0
            }
        )
        XCTAssertEqual(manager.runCount, 2)
        XCTAssertEqual(manager.maxConcurrentRuns, 1)
        manager.stopAfterburnTimerForTests()
    }

    func testCleanupTriggerReturnsQuickly() {
        let manager = SpyChatMarkersManager(owner: "owner@example.com")
        let runStarted = expectation(description: "run started")
        let gate = DispatchSemaphore(value: 0)
        manager.gate = gate
        manager.onRun = {
            runStarted.fulfill()
        }

        let start = Date()
        manager.deleteEphemeralMessages()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.05)
        wait(for: [runStarted], timeout: 1)
        gate.signal()
        XCTAssertTrue(waitUntil { manager.activeRuns == 0 && manager.runCount == 1 })
        manager.stopAfterburnTimerForTests()
    }

    func testTimerRescheduleKeepsSingleActiveTimerAtOneSecondCadenceAndTriggersImmediateCleanup() {
        let manager = SpyChatMarkersManager(owner: "owner@example.com")

        manager.updateDeleteEphemeralMessagesTimer()
        XCTAssertTrue(waitUntil { manager.runCount >= 1 })
        XCTAssertTrue(manager.hasAfterburnTimerForTests())
        XCTAssertEqual(manager.afterburnCleanupIntervalSeconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(manager.afterburnCleanupLeewayMilliseconds, 250)

        let firstTimerId = manager.afterburnTimerDebugIdentifierForTests()
        let firstRunCount = manager.runCount

        manager.updateDeleteEphemeralMessagesTimer()
        XCTAssertTrue(waitUntil { manager.runCount >= firstRunCount + 1 })
        XCTAssertTrue(manager.hasAfterburnTimerForTests())

        let secondTimerId = manager.afterburnTimerDebugIdentifierForTests()
        XCTAssertNotNil(firstTimerId)
        XCTAssertNotNil(secondTimerId)
        XCTAssertNotEqual(firstTimerId, secondTimerId)
        manager.stopAfterburnTimerForTests()
    }
}

final class AutoDeleteMessagesCleanupTests: XCTestCase {

    private let owner = "auto-delete-owner@example.com"
    private let jid = "auto-delete-chat@example.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "AutoDeleteMessagesCleanupTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func insertLastChat(lastMessage: MessageStorageItem) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.jid = jid
        chat.conversationType = .omemo
        chat.setPrimary(withOwner: owner)
        chat.lastMessage = lastMessage
        chat.messageDate = lastMessage.date

        try realm.write {
            realm.add(chat, update: .modified)
        }
    }

    private func makeMessage(
        primary: String,
        archivedId: String,
        body: String,
        date: Date,
        isRead: Bool
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = jid
        message.conversationType = .omemo
        message.messageId = primary
        message.archivedId = archivedId
        message.body = body
        message.legacyBody = body
        message.date = date
        message.sentDate = date
        message.isRead = isRead
        message.state = isRead ? .read : .deliver
        return message
    }

    func testSendTimeAutoDeleteExpiresUnreadMessagesAndRedactsNotifications() throws {
        let oldMessage = makeMessage(
            primary: "old-message",
            archivedId: "old-archived",
            body: "old",
            date: Date(timeIntervalSince1970: 10),
            isRead: true
        )
        let expiringMessage = makeMessage(
            primary: "expiring-message",
            archivedId: "expiring-archived",
            body: "secret",
            date: Date(timeIntervalSince1970: 20),
            isRead: false
        )
        expiringMessage.applyAutoDeleteTTL(5, startsAt: Date(timeIntervalSince1970: 20), policyVersion: 1)

        let notification = NotificationStorageItem()
        notification.primary = NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: "notification-1")
        notification.owner = owner
        notification.jid = jid
        notification.uniqueId = "notification-1"
        notification.messageId = expiringMessage.messageId
        notification.stanzaId = expiringMessage.archivedId
        notification.text = "secret"
        notification.fallbackText = "secret"
        notification.shouldShow = true
        notification.isRead = false
        notification.sourceArchivedId = expiringMessage.archivedId

        let realm = try WRealm.safe()
        try realm.write {
            realm.add(oldMessage, update: .modified)
            realm.add(expiringMessage, update: .modified)
            realm.add(notification, update: .modified)
        }
        try insertLastChat(lastMessage: expiringMessage)

        ChatMarkersManager(withOwner: owner, withoutAfterburnTimer: true).runEphemeralCleanup()

        let deleted = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "expiring-message"))
        XCTAssertTrue(deleted.isDeleted)
        XCTAssertEqual(deleted.deleteState, .autoDeleted)
        XCTAssertEqual(deleted.body, "")
        XCTAssertEqual(deleted.legacyBody, "")
        XCTAssertFalse(deleted.isRead)

        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .omemo)
            )
        )
        XCTAssertEqual(chat.lastMessage?.primary, "old-message")

        let redactedNotification = try XCTUnwrap(realm.object(ofType: NotificationStorageItem.self, forPrimaryKey: notification.primary))
        XCTAssertNil(redactedNotification.text)
        XCTAssertNil(redactedNotification.fallbackText)
        XCTAssertFalse(redactedNotification.shouldShow)
        XCTAssertTrue(redactedNotification.isRead)
    }

    func testLegacyUnreadAfterburnMessageWaitsForReadBeforeCleanup() throws {
        let message = makeMessage(
            primary: "legacy-message",
            archivedId: "legacy-archived",
            body: "legacy",
            date: Date(timeIntervalSince1970: 20),
            isRead: false
        )
        message.afterburnInterval = 5
        message.burnDate = Date(timeIntervalSince1970: 25).timeIntervalSince1970

        let realm = try WRealm.safe()
        try realm.write {
            realm.add(message, update: .modified)
        }
        try insertLastChat(lastMessage: message)

        ChatMarkersManager(withOwner: owner, withoutAfterburnTimer: true).runEphemeralCleanup()

        let stored = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "legacy-message"))
        XCTAssertFalse(stored.isDeleted)
        XCTAssertEqual(stored.body, "legacy")
    }
}

final class ContactsListSupportTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "ContactsListSupportTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeAccount(jid: String, username: String) -> AccountStorageItem {
        let account = AccountStorageItem()
        account.jid = jid
        account.username = username
        account.enabled = true
        return account
    }

    private func makeCircle(name: String, owner: String) -> RosterGroupStorageItem {
        let circle = RosterGroupStorageItem()
        circle.primary = RosterGroupStorageItem.genPrimary(name: name, owner: owner)
        circle.owner = owner
        circle.name = name
        return circle
    }

    private func makeContact(owner: String, jid: String, subscription: RosterStorageItem.Subsccribtion, ask: RosterStorageItem.Ask, groups: [String]) -> RosterStorageItem {
        let contact = RosterStorageItem()
        contact.primary = RosterStorageItem.genPrimary(jid: jid, owner: owner)
        contact.owner = owner
        contact.jid = jid
        contact.username = jid
        contact.isContact = true
        contact.subscribtion = subscription
        contact.ask = ask
        contact.groups.append(objectsIn: groups)
        return contact
    }

    func testContactCategoryDatasourceCountsJoinedContactsAndRequestsSeparately() throws {
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(makeAccount(jid: "owner-1@example.com", username: "Owner 1"))
            realm.add(makeCircle(name: "Friends", owner: "owner-1@example.com"))
            realm.add(makeContact(owner: "owner-1@example.com", jid: "alice@example.com", subscription: .both, ask: .none, groups: ["Friends"]))
            realm.add(makeContact(owner: "owner-1@example.com", jid: "bob@example.com", subscription: .none, ask: .out, groups: ["Friends"]))
            realm.add(makeContact(owner: "owner-1@example.com", jid: "carol@example.com", subscription: .none, ask: .in, groups: []))
        }

        let context = ContactsListSupport.makeContext(
            realm: realm,
            state: ContactsFilterState(category: "all", filteredAccounts: [], filteredGroups: [], showOffline: true, isGroup: false)
        )
        let datasource = ContactsListSupport.categoryDatasource(context: context)

        XCTAssertEqual(datasource[1].first?.subtitle, "1")
        XCTAssertEqual(datasource[2].first?.subtitle, "1")
        XCTAssertEqual(datasource[2].last?.subtitle, "1")
        XCTAssertEqual(datasource[3].first?.subtitle, "1")
    }

    func testCircleCountsRespectSelectedAccountFilter() throws {
        let realm = try WRealm.safe()
        try realm.write {
            realm.add(makeAccount(jid: "owner-1@example.com", username: "Owner 1"))
            realm.add(makeAccount(jid: "owner-2@example.com", username: "Owner 2"))
            realm.add(makeCircle(name: "Friends", owner: "owner-1@example.com"))
            realm.add(makeCircle(name: "Friends", owner: "owner-2@example.com"))
            realm.add(makeContact(owner: "owner-1@example.com", jid: "alice@example.com", subscription: .both, ask: .none, groups: ["Friends"]))
            realm.add(makeContact(owner: "owner-2@example.com", jid: "bob@example.com", subscription: .both, ask: .none, groups: ["Friends"]))
        }

        let allContext = ContactsListSupport.makeContext(
            realm: realm,
            state: ContactsFilterState(category: "all", filteredAccounts: [], filteredGroups: [], showOffline: true, isGroup: false)
        )
        let filteredContext = ContactsListSupport.makeContext(
            realm: realm,
            state: ContactsFilterState(category: "all", filteredAccounts: ["owner-1@example.com"], filteredGroups: [], showOffline: true, isGroup: false)
        )

        XCTAssertEqual(ContactsListSupport.circleCounts(context: allContext).first?.count, 2)
        XCTAssertEqual(ContactsListSupport.circleCounts(context: filteredContext).first?.count, 1)
    }
}

final class ClientSynchronizationManagerTests: XCTestCase {

    private let owner = "igor.boldin@xmppdev01.xabber.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "ClientSynchronizationManagerTests-\(name)")
        ClientSynchronizationManager.remove(for: owner, commitTransaction: false)
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "ClientSynchronizationManagerTests", code: 1)
        }
        return root
    }

    private func makeMessage(xml: String) throws -> XMPPMessage {
        XMPPMessage(from: try makeElement(xml: xml))
    }

    private func makeIQ(xml: String) throws -> XMPPIQ {
        XMPPIQ(from: try makeElement(xml: xml))
    }

    private func insertLastChat(
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType = .group
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)

        try realm.write {
            realm.add(chat, update: .modified)
        }
    }

    private func insertOutgoingMessage(
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType = .group,
        primary: String,
        date: Date,
        state: MessageStorageItem.MessageSendingState
    ) throws {
        let realm = try WRealm.safe()
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = jid
        message.conversationType = conversationType
        message.body = "hello"
        message.legacyBody = "hello"
        message.displayAs = .text
        message.messageId = primary
        message.archivedId = String(Int64(date.timeIntervalSince1970 * 1_000_000))
        message.outgoing = true
        message.isRead = false
        message.date = date
        message.sentDate = date
        message.state = state

        try realm.write {
            realm.add(message, update: .modified)
        }
    }

    private func upsertNotificationSyncStorage(
        node: String? = nil,
        unread: Int = 0,
        unreadAfterId: String? = nil
    ) throws {
        let realm = try WRealm.safe()
        let storage = XMPPNotificationsManagerStorageItem()
        storage.owner = owner
        storage.primary = XMPPNotificationsManagerStorageItem.genPrimary(owner: owner)
        storage.node = node
        storage.unread = unread
        storage.unreadAfterId = unreadAfterId

        try realm.write {
            realm.add(storage, update: .modified)
        }
    }

    @discardableResult
    private func insertStoredNotification(
        uniqueId: String,
        stanzaId: String,
        isRead: Bool
    ) throws -> NotificationStorageItem {
        let realm = try WRealm.safe()
        let notification = NotificationStorageItem()
        notification.primary = NotificationStorageItem.genPrimary(
            owner: owner,
            jid: "notifications.redsolution.com",
            uniqueId: uniqueId
        )
        notification.owner = owner
        notification.jid = "notifications.redsolution.com"
        notification.uniqueId = uniqueId
        notification.messageId = uniqueId
        notification.stanzaId = stanzaId
        notification.category = .info
        notification.isRead = isRead
        notification.shouldShow = true
        notification.date = Date(timeIntervalSince1970: 1_711_283_200)

        try realm.write {
            realm.add(notification, update: .modified)
        }

        return notification
    }

    private func notificationSyncStorage() throws -> XMPPNotificationsManagerStorageItem? {
        try WRealm.safe().object(
            ofType: XMPPNotificationsManagerStorageItem.self,
            forPrimaryKey: XMPPNotificationsManagerStorageItem.genPrimary(owner: owner)
        )
    }

    private func storedRecognizedStamp() -> String? {
        SettingManager.shared.getKey(
            for: owner,
            scope: .clientSynchronization,
            key: "last_recognized_event_stamp"
        )
    }

    private func prepareManagedAccount() throws {
        let realm = try WRealm.safe()
        if realm.object(ofType: AccountStorageItem.self, forPrimaryKey: owner) == nil {
            try realm.write {
                let account = AccountStorageItem()
                account.jid = owner
                account.username = "igor.boldin"
                account.enabled = true
                realm.add(account, update: .modified)
            }
        }

        AccountManager.shared.add(withJid: owner, autoConnect: false)
        AccountManager.shared.find(for: owner)?.blocked.lastUpdate = Date()
    }

    func testArchivedMessageDatePrefersMessageTimeStamp() throws {
        let message = try makeElement(xml: """
        <message from='romeo@xmppdev01.xabber.com' to='\(owner)'>
          <time xmlns='https://xabber.com/protocol/delivery' stamp='2026-03-24T12:34:56Z'/>
        </message>
        """)

        let normalizedStamp = ClientSynchronizationManager.syncStamp(from: message, fallback: 1_700_000_000_000_000)
        let archivedDate = ClientSynchronizationManager.archivedMessageDate(from: message, fallbackSyncStamp: 1_700_000_000_000_000)

        XCTAssertEqual(normalizedStamp, 1_774_355_696_000_000, accuracy: 1)
        XCTAssertEqual(archivedDate.timeIntervalSince1970, 1_774_355_696, accuracy: 0.001)
    }

    func testReadSnapshotRejectsNonHttpsNamespace() throws {
        let manager = ClientSynchronizationManager(withOwner: owner)
        let iq = try makeIQ(xml: """
        <iq type='result' id='sync-1'>
          <query xmlns='http://xabber.com/protocol/synchronization' stamp='1711283296000000'>
          </query>
        </iq>
        """)

        XCTAssertFalse(manager.read(withIQ: iq))
    }

    func testClientSyncPageParserParsesSnapshotPage() throws {
        let iq = try makeIQ(xml: """
        <iq type='result' id='sync-2'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000000'>
            <conversation jid='romeo@example.com' type='regular' status='active'/>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <count>1</count>
            </set>
          </query>
        </iq>
        """)

        let page = ClientSyncPageParser.parseSnapshotPage(
            from: iq,
            pageSize: 200,
            namespace: ClientSynchronizationManager.primaryNamespace,
            updateOmemo: { $0 }
        )

        XCTAssertEqual(page?.stamp, "1711283296000000")
        XCTAssertEqual(page?.conversations.count, 1)
        XCTAssertEqual(page?.isFinalPage, true)
    }

    func testClientSyncPageParserKeepsContinuationWhenPageIsFull() throws {
        let iq = try makeIQ(xml: """
        <iq type='result' id='sync-2b'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000000'>
            <conversation jid='romeo@example.com' type='regular' status='active'/>
            <set xmlns='http://jabber.org/protocol/rsm'>
              <last>page-1</last>
              <count>120</count>
            </set>
          </query>
        </iq>
        """)

        let page = ClientSyncPageParser.parseSnapshotPage(
            from: iq,
            pageSize: 1,
            namespace: ClientSynchronizationManager.primaryNamespace,
            updateOmemo: { $0 }
        )

        XCTAssertEqual(page?.nextPageToken, "page-1")
        XCTAssertEqual(page?.isFinalPage, false)
    }

    func testDuplicateInviteIsIgnored() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let account = AccountStorageItem()
            account.jid = owner
            account.username = "igor.boldin"
            account.enabled = true
            realm.add(account, update: .modified)
        }

        let manager = GroupchatManager(withOwner: owner)
        let inviteMessage = try makeMessage(xml: """
        <message from='romeo@xmppdev01.xabber.com' to='\(owner)' id='invite-1'>
          <invite xmlns='https://xabber.com/protocol/groups' jid='group@conference.xabber.com'>
            <reason>Join us</reason>
          </invite>
          <group xmlns='https://xabber.com/protocol/groups' privacy='public'/>
        </message>
        """)
        let inviteDate = ISO8601DateFormatter().date(from: "2026-03-24T12:34:56Z")!

        XCTAssertTrue(manager.readInvite(in: inviteMessage, date: inviteDate, isRead: false))
        XCTAssertFalse(manager.readInvite(in: inviteMessage, date: inviteDate, isRead: false))

        let storedInvites = try WRealm.safe()
            .objects(GroupchatInvitesStorageItem.self)
            .filter("owner == %@", owner)
        XCTAssertEqual(storedInvites.count, 1)
    }

    func testReadPushUpdatesPinnedWithoutStatus() throws {
        let manager = ClientSynchronizationManager(withOwner: owner)
        let groupchat = "group@example.com"
        try insertLastChat(jid: groupchat)

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-pinned'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000001'>
            <conversation jid='\(groupchat)' type='https://xabber.com/protocol/groups' pinned='42'/>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let chat = try WRealm.safe().object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: groupchat, owner: owner, conversationType: .group)
        )
        XCTAssertEqual(chat?.pinnedPosition, 42)
        XCTAssertEqual(chat?.isPinned, true)
    }

    func testReadPushUpdatesMuteWithoutStatus() throws {
        let manager = ClientSynchronizationManager(withOwner: owner)
        let groupchat = "group@example.com"
        try insertLastChat(jid: groupchat)

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-mute'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000002'>
            <conversation jid='\(groupchat)' type='https://xabber.com/protocol/groups' mute='99'/>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let chat = try WRealm.safe().object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: groupchat, owner: owner, conversationType: .group)
        )
        XCTAssertEqual(chat?.muteExpired, 99)
    }

    func testReadPushUpdatesDeliveredMarkerWithoutDisplayed() throws {
        let manager = ClientSynchronizationManager(withOwner: owner)
        let groupchat = "group@example.com"
        try insertLastChat(jid: groupchat)
        let messageDate = Date(timeIntervalSince1970: 1_711_283_200)
        try insertOutgoingMessage(
            jid: groupchat,
            primary: "outgoing-delivered",
            date: messageDate,
            state: .sended
        )

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-delivered'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000005'>
            <conversation jid='\(groupchat)' type='https://xabber.com/protocol/groups' stamp='1711283296000005'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <delivered id='1711283296000000'/>
              </metadata>
            </conversation>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let message = try WRealm.safe().object(ofType: MessageStorageItem.self, forPrimaryKey: "outgoing-delivered")
        XCTAssertEqual(message?.state, .deliver)
    }

    func testReadPushUpdatesDisplayedMarkerWithoutDelivered() throws {
        let manager = ClientSynchronizationManager(withOwner: owner)
        let groupchat = "group@example.com"
        try insertLastChat(jid: groupchat)
        let messageDate = Date(timeIntervalSince1970: 1_711_283_200)
        try insertOutgoingMessage(
            jid: groupchat,
            primary: "outgoing-read",
            date: messageDate,
            state: .deliver
        )

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-displayed'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000006'>
            <conversation jid='\(groupchat)' type='https://xabber.com/protocol/groups' stamp='1711283296000006'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <displayed id='1711283296000000'/>
              </metadata>
            </conversation>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let message = try WRealm.safe().object(ofType: MessageStorageItem.self, forPrimaryKey: "outgoing-read")
        XCTAssertEqual(message?.state, .read)
        XCTAssertEqual(message?.isRead, true)
    }

    func testReadPushUpdatesUnreadStateAndLastMessageMetadata() throws {
        try prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-last-message'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000007'>
            <conversation jid='romeo@xmppdev01.xabber.com' type='urn:xabber:chat' stamp='1711283296000007' status='active'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <unread count='2' after='1711283295000000'/>
                <last-message>
                  <message from='romeo@xmppdev01.xabber.com' to='\(owner)' id='sync-last-message-1'>
                    <body>Hello Juliet</body>
                    <time xmlns='https://xabber.com/protocol/delivery' stamp='2026-03-24T12:34:56Z'/>
                  </message>
                </last-message>
              </metadata>
            </conversation>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let chat = try WRealm.safe().object(
            ofType: LastChatsStorageItem.self,
            forPrimaryKey: LastChatsStorageItem.genPrimary(jid: "romeo@xmppdev01.xabber.com", owner: owner, conversationType: .regular)
        )
        XCTAssertEqual(chat?.unread, 2)
        XCTAssertEqual(chat?.lastReadId, "1711283295000000")
        XCTAssertEqual(chat?.lastMessageId, "sync-last-message-1")
    }

    func testNotificationSnapshotUnreadStatePersistsUnreadBoundaryAndKeepsExistingNode() throws {
        try upsertNotificationSyncStorage(
            node: "notifications.saved.example.com",
            unread: 1,
            unreadAfterId: "old-boundary"
        )
        let manager = ClientSynchronizationManager(withOwner: owner)

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-notification-unread'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1776840442469439'>
            <conversation pinned='0' stamp='1776840442469439' status='active' type='urn:xabber:xen:0' jid='notifications.redsolution.com'>
              <metadata node='https://xabber.com/protocol/rewrite'>
                <retract version='263'/>
              </metadata>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <unread after='1776509222888890' count='5'/>
                <displayed id='0'/>
                <delivered id='0'/>
                <last-message>
                  <message from='notifications.redsolution.com' to='\(owner)' id='3744502549003287214'>
                    <archived xmlns='urn:xmpp:mam:tmp' by='\(owner)' id='1776840442467416'/>
                    <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='1776840442467416'/>
                    <body>Unread notification</body>
                  </message>
                </last-message>
              </metadata>
            </conversation>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let storage = try XCTUnwrap(try notificationSyncStorage())
        XCTAssertEqual(storage.node, "notifications.saved.example.com")
        XCTAssertEqual(storage.unread, 5)
        XCTAssertEqual(storage.unreadAfterId, "1776509222888890")
    }

    func testNotificationSnapshotMarksStoredNotificationsReadWhenUnreadCountIsZero() throws {
        try insertStoredNotification(uniqueId: "notif-1", stanzaId: "1776509222888890", isRead: false)
        try insertStoredNotification(uniqueId: "notif-2", stanzaId: "1776840442467416", isRead: false)
        let manager = ClientSynchronizationManager(withOwner: owner)

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-notification-read-all'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1776840442469439'>
            <conversation stamp='1776840442469439' status='active' type='urn:xabber:xen:0' jid='notifications.redsolution.com'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <unread after='1776840442467416' count='0'/>
              </metadata>
            </conversation>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let storage = try XCTUnwrap(try notificationSyncStorage())
        XCTAssertEqual(storage.unread, 0)
        XCTAssertEqual(storage.unreadAfterId, "1776840442467416")

        let notifications = try WRealm.safe()
            .objects(NotificationStorageItem.self)
            .filter("owner == %@", owner)
            .toArray()
        XCTAssertTrue(notifications.allSatisfy(\.isRead))
    }

    func testNotificationSnapshotReconcilesStoredNotificationsUsingUnreadBoundaryAndIgnoresMarkers() throws {
        try insertStoredNotification(uniqueId: "notif-read", stanzaId: "1776509222888890", isRead: false)
        try insertStoredNotification(uniqueId: "notif-unread", stanzaId: "1776840442467416", isRead: true)
        let manager = ClientSynchronizationManager(withOwner: owner)

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-notification-boundary'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1776840442469439'>
            <conversation stamp='1776840442469439' status='active' type='urn:xabber:xen:0' jid='notifications.redsolution.com'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <unread after='1776509222888890' count='1'/>
                <displayed id='1776840442467416'/>
                <delivered id='1776840442467416'/>
              </metadata>
            </conversation>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let realm = try WRealm.safe()
        let readNotification = try XCTUnwrap(
            realm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: NotificationStorageItem.genPrimary(
                    owner: owner,
                    jid: "notifications.redsolution.com",
                    uniqueId: "notif-read"
                )
            )
        )
        let unreadNotification = try XCTUnwrap(
            realm.object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: NotificationStorageItem.genPrimary(
                    owner: owner,
                    jid: "notifications.redsolution.com",
                    uniqueId: "notif-unread"
                )
            )
        )
        XCTAssertTrue(readNotification.isRead)
        XCTAssertFalse(unreadNotification.isRead)
    }

    func testNotificationSnapshotWithoutUnreadKeepsExistingNotificationUnreadState() throws {
        try upsertNotificationSyncStorage(
            node: "notifications.redsolution.com",
            unread: 3,
            unreadAfterId: "1776509222888890"
        )
        try insertStoredNotification(uniqueId: "notif-existing", stanzaId: "1776840442467416", isRead: false)
        let manager = ClientSynchronizationManager(withOwner: owner)

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-notification-no-unread'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1776840442469440'>
            <conversation stamp='1776840442469440' status='active' type='urn:xabber:xen:0' jid='notifications.redsolution.com'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <displayed id='0'/>
                <delivered id='0'/>
              </metadata>
            </conversation>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let storage = try XCTUnwrap(try notificationSyncStorage())
        XCTAssertEqual(storage.unread, 3)
        XCTAssertEqual(storage.unreadAfterId, "1776509222888890")
        let notification = try XCTUnwrap(
            try WRealm.safe().object(
                ofType: NotificationStorageItem.self,
                forPrimaryKey: NotificationStorageItem.genPrimary(
                    owner: owner,
                    jid: "notifications.redsolution.com",
                    uniqueId: "notif-existing"
                )
            )
        )
        XCTAssertFalse(notification.isRead)
    }

    func testReadPushStoresGroupInviteFromLastMessage() throws {
        try prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-invite'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000003'>
            <conversation jid='group@conference.xabber.com' type='https://xabber.com/protocol/groups' stamp='1711283296000003' status='active'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <last-message>
                  <message from='romeo@xmppdev01.xabber.com' to='\(owner)' id='invite-push-1'>
                    <invite xmlns='https://xabber.com/protocol/groups' jid='group@conference.xabber.com'>
                      <reason>Join us</reason>
                    </invite>
                    <group xmlns='https://xabber.com/protocol/groups' privacy='public'/>
                    <body>Join us</body>
                  </message>
                </last-message>
              </metadata>
            </conversation>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let invites = try WRealm.safe()
            .objects(GroupchatInvitesStorageItem.self)
            .filter("owner == %@ AND groupchat == %@", owner, "group@conference.xabber.com")
        XCTAssertEqual(invites.count, 1)
    }

    func testReadPushUpdatesGroupParticipantCardMetadata() throws {
        try prepareManagedAccount()
        let manager = ClientSynchronizationManager(withOwner: owner)

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-user-card'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000004'>
            <conversation jid='group@example.com' type='https://xabber.com/protocol/groups' stamp='1711283296000004' status='active'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <unread count='0' after='0'/>
              </metadata>
              <metadata node='https://xabber.com/protocol/groups'>
                <user xmlns='https://xabber.com/protocol/groups' id='user-1'>
                  <nickname>Romeo</nickname>
                  <role>member</role>
                </user>
              </metadata>
            </conversation>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let realm = try WRealm.safe()
        let user = realm.object(
            ofType: GroupchatUserStorageItem.self,
            forPrimaryKey: GroupchatUserStorageItem.genPrimary(id: "user-1", groupchat: "group@example.com", owner: owner)
        )
        XCTAssertEqual(user?.nickname, "Romeo")
        XCTAssertEqual(user?.role, .member)
    }

    func testReadPushDeletesConversationAndMessages() throws {
        let manager = ClientSynchronizationManager(withOwner: owner)
        let jid = "group@example.com"
        try insertLastChat(jid: jid)
        try insertOutgoingMessage(
            jid: jid,
            primary: "deleted-message",
            date: Date(timeIntervalSince1970: 1_711_283_200),
            state: .sended
        )

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-delete'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000008'>
            <conversation jid='\(jid)' type='https://xabber.com/protocol/groups' status='deleted'/>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))

        let realm = try WRealm.safe()
        XCTAssertNil(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: .group)
            )
        )
        XCTAssertNil(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "deleted-message"))
    }

    func testSyncErrorAllowsRetryingFullSync() throws {
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.isAvailable = true
        let stream = XMPPStream()

        XCTAssertTrue(manager.sync(stream))
        let firstQueryId = try XCTUnwrap(manager.queryIds.last)

        let iq = try makeIQ(xml: """
        <iq type='error' id='\(firstQueryId)'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000009'/>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))
        XCTAssertTrue(manager.sync(stream))
    }

    func testFailedPushApplyDoesNotAdvanceRecognizedStamp() throws {
        let manager = ClientSynchronizationManager(withOwner: owner)
        manager.beforeApplyingSyncPayload = {
            throw NSError(domain: "ClientSynchronizationManagerTests", code: 99)
        }

        let iq = try makeIQ(xml: """
        <iq type='set' id='push-failure'>
          <query xmlns='https://xabber.com/protocol/synchronization' stamp='1711283296000010'>
            <conversation jid='romeo@xmppdev01.xabber.com' type='urn:xabber:chat' stamp='1711283296000010'>
              <metadata node='https://xabber.com/protocol/synchronization'>
                <unread count='1' after='1711283295000000'/>
              </metadata>
            </conversation>
          </query>
        </iq>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))
        XCTAssertTrue(storedRecognizedStamp()?.isEmpty ?? true)
    }
}

final class ChatListUnreadMentionBadgeTests: XCTestCase {

    private let owner = "igor.boldin@xmppdev01.xabber.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "ChatListUnreadMentionBadgeTests-\(name)")
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func insertLastChat(
        jid: String = "group@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .group,
        mentionId: String? = nil,
        unread: Int = 0
    ) throws {
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        chat.mentionId = mentionId
        chat.unread = unread
        chat.messageDate = Date(timeIntervalSince1970: 1_711_283_200)

        try realm.write {
            realm.add(chat, update: .modified)
        }
    }

    private func insertMessage(
        jid: String = "group@example.com",
        conversationType: ClientSynchronizationManager.ConversationType = .group,
        primary: String = "message-primary"
    ) throws -> MessageStorageItem {
        let realm = try WRealm.safe()
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = jid
        message.conversationType = conversationType
        message.body = "Hello"
        message.legacyBody = "Hello"
        message.displayAs = .text
        message.date = Date(timeIntervalSince1970: 1_711_283_201)
        message.sentDate = message.date
        message.outgoing = false
        message.messageId = primary

        try realm.write {
            realm.add(message, update: .modified)
        }

        return message
    }

    private func insertUnreadMentionNotification(
        jid: String = "group@example.com",
        archivedId: String = "mention-1",
        messageId: String = "origin-1",
        authorId: String = "author-1",
        date: Date = Date(timeIntervalSince1970: 1_711_283_201)
    ) throws {
        let realm = try WRealm.safe()
        let notification = NotificationStorageItem()
        notification.primary = NotificationStorageItem.genPrimary(owner: owner, jid: jid, uniqueId: archivedId)
        notification.owner = owner
        notification.jid = jid
        notification.uniqueId = archivedId
        notification.messageId = archivedId
        notification.category = .mention
        notification.isRead = false
        notification.shouldShow = true
        notification.sourceConversationType = .group
        notification.sourceChatJid = jid
        notification.sourceArchivedId = archivedId
        notification.sourceMessageId = messageId
        notification.sourceSenderId = authorId
        notification.sourceMessageDate = date
        notification.sourceBodyFingerprint = MentionNotificationSync.normalizedBodyFingerprint("Hello @you")
        notification.mentionLinkStatus = .resolved

        try realm.write {
            realm.add(notification, update: .modified)
        }
    }

    private func waitFor(
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        XCTFail("Condition was not met before timeout", file: file, line: line)
    }

    private func makeDatasource(hasUnreadMention: Bool) -> LastChatsViewController.Datasource {
        LastChatsViewController.Datasource(
            jid: "group@example.com",
            owner: owner,
            username: "Group",
            attributedUsername: nil,
            message: "Hello",
            date: Date(timeIntervalSince1970: 1_711_283_200),
            state: nil,
            isMute: false,
            isSynced: true,
            status: .offline,
            entity: .groupchat,
            conversationType: .group,
            unread: 0,
            unreadString: nil,
            hasUnreadMention: hasUnreadMention,
            color: .clear,
            isDraft: false,
            hasAttachment: false,
            userNickname: nil,
            isSystemMessage: false,
            isPinned: false,
            subRequest: false,
            isEncrypted: false,
            avatarUrl: nil,
            hasErrorInChat: false,
            updateTS: 0,
            isVerificationActionRequired: false,
            specialMessageKind: .none,
            avatars: []
        )
    }

    func testLastChatsStorageUnreadMentionFlagIsGroupOnly() throws {
        try insertLastChat(
            jid: "group@example.com",
            conversationType: .group,
            mentionId: "mention-1"
        )
        try insertLastChat(
            jid: "romeo@example.com",
            conversationType: .regular,
            mentionId: "mention-2"
        )

        let realm = try WRealm.safe()
        let groupchat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: "group@example.com", owner: owner, conversationType: .group)
            )
        )
        let directChat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: "romeo@example.com", owner: owner, conversationType: .regular)
            )
        )

        XCTAssertTrue(groupchat.hasUnreadMention)
        XCTAssertFalse(directChat.hasUnreadMention)
    }

    func testLastChatsStorageUnreadMentionFlagIsFalseForGroupWithoutMentionId() throws {
        try insertLastChat(
            jid: "group@example.com",
            conversationType: .group,
            mentionId: nil,
            unread: 3
        )

        let realm = try WRealm.safe()
        let groupchat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: "group@example.com", owner: owner, conversationType: .group)
            )
        )

        XCTAssertFalse(groupchat.hasUnreadMention)
        XCTAssertEqual(groupchat.unread, 3)
    }

    func testChatListCellShowsUnreadMentionBadgeWithoutUnreadCounter() {
        let cell = ChatListTableViewCell(style: .default, reuseIdentifier: nil)

        cell.configure(
            "group@example.com",
            owner: owner,
            username: "Group",
            attributedUsername: nil,
            message: "Hello",
            date: Date(timeIntervalSince1970: 1_711_283_200),
            deliveryState: nil,
            isMute: false,
            isSynced: true,
            isGroupchat: true,
            status: .offline,
            entity: .groupchat,
            conversationType: .group,
            unread: 0,
            unreadString: nil,
            hasUnreadMention: true,
            indicator: .clear,
            isDraft: false,
            isAttachment: false,
            groupchatNickname: nil,
            isSystem: false,
            isPinned: false,
            subRequest: false,
            avatarUrl: nil,
            hasErrorInChat: false,
            verAction: false
        )

        XCTAssertFalse(cell.mentionBadgeView.isHidden)
        XCTAssertTrue(cell.badgeView.isHidden)
        XCTAssertTrue(cell.mentionBadgeView.tintColor.isEqual(UIColor(red: 0.2196, green: 0.5569, blue: 0.2353, alpha: 1.0)))
    }

    func testChatListCellUsesMutedMentionBadgeTint() {
        let cell = ChatListTableViewCell(style: .default, reuseIdentifier: nil)

        cell.configure(
            "group@example.com",
            owner: owner,
            username: "Group",
            attributedUsername: nil,
            message: "Hello",
            date: Date(timeIntervalSince1970: 1_711_283_200),
            deliveryState: nil,
            isMute: true,
            isSynced: true,
            isGroupchat: true,
            status: .offline,
            entity: .groupchat,
            conversationType: .group,
            unread: 3,
            unreadString: nil,
            hasUnreadMention: true,
            indicator: .clear,
            isDraft: false,
            isAttachment: false,
            groupchatNickname: nil,
            isSystem: false,
            isPinned: false,
            subRequest: false,
            avatarUrl: nil,
            hasErrorInChat: false,
            verAction: false
        )

        XCTAssertFalse(cell.mentionBadgeView.isHidden)
        XCTAssertTrue(cell.mentionBadgeView.tintColor.isEqual(UIColor(red: 189/255, green: 189/255, blue: 189/255, alpha: 1.0)))
    }

    func testChatListCellHidesMentionBadgeWhenGroupHasUnreadMessagesButNoMention() {
        let cell = ChatListTableViewCell(style: .default, reuseIdentifier: nil)

        cell.configure(
            "group@example.com",
            owner: owner,
            username: "Group",
            attributedUsername: nil,
            message: "Hello",
            date: Date(timeIntervalSince1970: 1_711_283_200),
            deliveryState: nil,
            isMute: false,
            isSynced: true,
            isGroupchat: true,
            status: .offline,
            entity: .groupchat,
            conversationType: .group,
            unread: 3,
            unreadString: nil,
            hasUnreadMention: false,
            indicator: .clear,
            isDraft: false,
            isAttachment: false,
            groupchatNickname: nil,
            isSystem: false,
            isPinned: false,
            subRequest: false,
            avatarUrl: nil,
            hasErrorInChat: false,
            verAction: false
        )

        XCTAssertTrue(cell.mentionBadgeView.isHidden)
        XCTAssertFalse(cell.badgeView.isHidden)
    }

    func testLastChatsDatasourceCompareContentTracksUnreadMentionFlag() {
        let withoutMention = makeDatasource(hasUnreadMention: false)
        let withMention = makeDatasource(hasUnreadMention: true)

        XCTAssertFalse(LastChatsViewController.Datasource.compareContent(withoutMention, withMention))
    }

    func testLastChatsViewControllerMapsUnreadMentionFlagFromStorage() throws {
        try insertLastChat(
            jid: "group@example.com",
            conversationType: .group,
            mentionId: "mention-1"
        )

        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()
        controller.enabledAccounts.accept(Set([owner]))
        controller.updateDatasource(.chats)
        controller.showSkeleton.accept(false)

        waitFor {
            controller.datasource.contains {
                $0.jid == "group@example.com" && $0.owner == self.owner && $0.hasUnreadMention
            }
        }

        XCTAssertTrue(
            controller.datasource.contains {
                $0.jid == "group@example.com" && $0.owner == self.owner && $0.hasUnreadMention
            }
        )
    }

    func testLastChatsViewControllerDoesNotMapDirectChatMentionIdToUnreadMentionFlag() throws {
        try insertLastChat(
            jid: "romeo@example.com",
            conversationType: .regular,
            mentionId: "mention-1"
        )

        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()
        controller.enabledAccounts.accept(Set([owner]))
        controller.updateDatasource(.chats)
        controller.showSkeleton.accept(false)

        waitFor {
            controller.datasource.contains {
                $0.jid == "romeo@example.com" && $0.owner == self.owner
            }
        }

        XCTAssertTrue(
            controller.datasource.contains {
                $0.jid == "romeo@example.com" && $0.owner == self.owner && !$0.hasUnreadMention
            }
        )
    }

    func testLastChatsViewControllerRefreshesMentionFlagWhenMentionIdChanges() throws {
        try insertLastChat(
            jid: "group@example.com",
            conversationType: .group,
            mentionId: nil
        )

        let controller = LastChatsViewController()
        controller.loadViewIfNeeded()
        controller.enabledAccounts.accept(Set([owner]))
        controller.updateDatasource(.chats)
        controller.showSkeleton.accept(false)

        waitFor {
            controller.datasource.contains {
                $0.jid == "group@example.com" && $0.owner == self.owner && !$0.hasUnreadMention
            }
        }

        let realm = try WRealm.safe()
        let primary = LastChatsStorageItem.genPrimary(jid: "group@example.com", owner: owner, conversationType: .group)
        let chat = try XCTUnwrap(realm.object(ofType: LastChatsStorageItem.self, forPrimaryKey: primary))

        try realm.write {
            chat.mentionId = "mention-1"
        }
        controller.updateDatasource(.chats)

        waitFor {
            controller.datasource.contains {
                $0.jid == "group@example.com" && $0.owner == self.owner && $0.hasUnreadMention
            }
        }

        try realm.write {
            chat.mentionId = nil
        }
        controller.updateDatasource(.chats)

        waitFor {
            controller.datasource.contains {
                $0.jid == "group@example.com" && $0.owner == self.owner && !$0.hasUnreadMention
            }
        }
    }

    func testLastChatsUnreadMentionOpenRequestUsesUnreadNotificationAnchorMetadata() throws {
        try insertLastChat(
            jid: "group@example.com",
            conversationType: .group,
            mentionId: "mention-1"
        )
        try insertUnreadMentionNotification(
            jid: "group@example.com",
            archivedId: "mention-1",
            messageId: "origin-77",
            authorId: "author-77",
            date: Date(timeIntervalSince1970: 1_711_283_299)
        )
        let realm = try WRealm.safe()

        let request = try XCTUnwrap(
            LastChatsViewController.unreadMentionOpenRequest(
                owner: owner,
                jid: "group@example.com",
                conversationType: .group,
                in: realm
            )
        )

        XCTAssertEqual(request.chatJid, "group@example.com")
        XCTAssertEqual(request.anchor.archivedId, "mention-1")
        XCTAssertEqual(request.anchor.messageId, "origin-77")
        XCTAssertEqual(request.anchor.authorId, "author-77")
        XCTAssertEqual(request.anchor.bodyFingerprint, MentionNotificationSync.normalizedBodyFingerprint("Hello @you"))
        XCTAssertEqual(request.anchor.sourceDate, Date(timeIntervalSince1970: 1_711_283_299))
        XCTAssertEqual(request.source, .mentionNotification)
        XCTAssertTrue(request.markReadOnVisible)
        XCTAssertFalse(request.highlight)
    }

    func testLastChatsUnreadMentionOpenRequestFallsBackToStoredMentionIdWhenNotificationMetadataIsUnavailable() throws {
        try insertLastChat(
            jid: "group@example.com",
            conversationType: .group,
            mentionId: "mention-1"
        )
        let realm = try WRealm.safe()

        let request = try XCTUnwrap(
            LastChatsViewController.unreadMentionOpenRequest(
                owner: owner,
                jid: "group@example.com",
                conversationType: .group,
                in: realm
            )
        )

        XCTAssertEqual(request.anchor.archivedId, "mention-1")
        XCTAssertNil(request.anchor.messageId)
        XCTAssertNil(request.anchor.authorId)
        XCTAssertEqual(request.anchor.sourceDate, Date(timeIntervalSince1970: 1_711_283_200))
    }

    func testSearchChatListMapperCarriesUnreadMentionFlagForGroupResults() throws {
        try insertLastChat(
            jid: "group@example.com",
            conversationType: .group,
            mentionId: "mention-1"
        )
        let message = try insertMessage(
            jid: "group@example.com",
            conversationType: .group
        )

        let controller = SearchChatListViewController()
        controller.owner = owner
        let mapped = try controller.mapDatasource([message])

        XCTAssertEqual(mapped.count, 1)
        XCTAssertTrue(mapped.first?.hasUnreadMention == true)
    }
}

final class GroupchatRequestSchedulerTests: XCTestCase {

    func testCancelPreventsScheduledTimeoutCallback() {
        let scheduler = GroupchatRequestScheduler()
        let invertedExpectation = expectation(description: "timeout should be cancelled")
        invertedExpectation.isInverted = true

        scheduler.schedule(elementId: "timeout-1", timeout: 0.05) {
            invertedExpectation.fulfill()
        }
        scheduler.cancel(elementId: "timeout-1")

        wait(for: [invertedExpectation], timeout: 0.15)
    }
}

final class GroupchatProtocolRegressionTests: XCTestCase {

    private let owner = "igor.boldin@xmppdev01.xabber.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "GroupchatProtocolRegressionTests-\(name)")
        AccountManager.shared.users.removeAll()
        AccountManager.shared.activeUsers.accept(Set<String>())
        AccountManager.shared.connectingUsers.accept(Set<String>())
        AccountManager.shared.authenticatedUsers.accept(Set<String>())
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "GroupchatProtocolRegressionTests", code: 1)
        }
        return root
    }

    private func makeIQ(xml: String) throws -> XMPPIQ {
        XMPPIQ(from: try makeElement(xml: xml))
    }

    private func makeUserCard(xml: String) throws -> DDXMLElement {
        try makeElement(xml: xml)
    }

    private func queueItemCount(in manager: GroupchatManager) -> Int {
        let mirror = Mirror(reflecting: manager)
        guard let value = mirror.children.first(where: { $0.label == "queueItems" })?.value as? SynchronizedArray<GroupchatManager.QueueItem> else {
            XCTFail("queueItems should be reflectable")
            return -1
        }
        return value.count
    }

    func testBlockListRefreshClearsUsersMissingFromServerResponse() throws {
        let realm = try WRealm.safe()
        let groupchat = "group@example.com"
        let staleUser = GroupchatUserStorageItem()
        staleUser.owner = owner
        staleUser.userId = "stale@example.com"
        staleUser.groupchatId = [groupchat, owner].prp()
        staleUser.primary = GroupchatUserStorageItem.genPrimary(id: staleUser.userId, groupchat: groupchat, owner: owner)
        staleUser.isBlocked = true

        let currentUser = GroupchatUserStorageItem()
        currentUser.owner = owner
        currentUser.userId = "current@example.com"
        currentUser.groupchatId = [groupchat, owner].prp()
        currentUser.primary = GroupchatUserStorageItem.genPrimary(id: currentUser.userId, groupchat: groupchat, owner: owner)
        currentUser.isBlocked = false

        try realm.write {
            realm.add(staleUser, update: .modified)
            realm.add(currentUser, update: .modified)
        }

        let manager = GroupchatManager(withOwner: owner)
        let stream = XMPPStream()
        manager.blockList(stream, groupchat: groupchat)
        let elementId = manager.queryIds.last ?? ""

        let iq = try makeIQ(xml: """
        <iq type='result' from='\(groupchat)' id='\(elementId)'>
          <block xmlns='https://xabber.com/protocol/groups'>
            <jid>current@example.com</jid>
          </block>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))

        let stale = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: staleUser.primary)
        let current = realm.object(ofType: GroupchatUserStorageItem.self, forPrimaryKey: currentUser.primary)
        XCTAssertEqual(stale?.isBlocked, false)
        XCTAssertEqual(current?.isBlocked, true)
        XCTAssertEqual(manager.queryIds.count, 0)
    }

    func testUpdateUserCardWithoutPresentKeepsExistingPresence() throws {
        let manager = GroupchatManager(withOwner: owner)
        let initial = try makeUserCard(xml: """
        <user xmlns='https://xabber.com/protocol/groups' id='user-1'>
          <nickname>Romeo</nickname>
          <present>now</present>
        </user>
        """)
        let update = try makeUserCard(xml: """
        <user xmlns='https://xabber.com/protocol/groups' id='user-1'>
          <nickname>Romeo+</nickname>
        </user>
        """)

        _ = manager.updateUserCard(
            initial,
            groupchat: "group@example.com",
            trustedSource: true,
            messageAction: nil,
            commitTransaction: true,
            cardDate: Date(timeIntervalSince1970: 10)
        )

        let before = try WRealm.safe().object(
            ofType: GroupchatUserStorageItem.self,
            forPrimaryKey: GroupchatUserStorageItem.genPrimary(id: "user-1", groupchat: "group@example.com", owner: owner)
        )
        let beforeLastSeen = before?.lastSeen

        _ = manager.updateUserCard(
            update,
            groupchat: "group@example.com",
            trustedSource: true,
            messageAction: nil,
            commitTransaction: true,
            cardDate: Date(timeIntervalSince1970: 20)
        )

        let user = try WRealm.safe().object(
            ofType: GroupchatUserStorageItem.self,
            forPrimaryKey: GroupchatUserStorageItem.genPrimary(id: "user-1", groupchat: "group@example.com", owner: owner)
        )
        XCTAssertEqual(user?.nickname, "Romeo+")
        XCTAssertEqual(user?.isOnline, true)
        XCTAssertEqual(user?.lastSeen, beforeLastSeen)
    }

    func testSuccessfulUnblockClearsRequestTracking() throws {
        let manager = GroupchatManager(withOwner: owner)
        let stream = XMPPStream()
        manager.unblockUser(stream, groupchat: "group@example.com", jids: ["user@example.com"]) { _ in }
        let elementId = manager.queryIds.last ?? ""

        let iq = try makeIQ(xml: """
        <iq type='result' from='group@example.com' id='\(elementId)'/>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        XCTAssertEqual(manager.queryIds.count, 0)
        XCTAssertEqual(queueItemCount(in: manager), 0)
    }

    func testSuccessfulInviteListReadClearsQueryTracking() throws {
        let manager = GroupchatManager(withOwner: owner)
        let stream = XMPPStream()
        manager.requestInvitedUsers(stream, groupchat: "group@example.com")
        let elementId = manager.queryIds.last ?? ""

        let iq = try makeIQ(xml: """
        <iq type='result' from='group@example.com' id='\(elementId)'>
          <invites xmlns='https://xabber.com/protocol/groups'>
            <jid>user@example.com</jid>
          </invites>
        </iq>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        XCTAssertEqual(manager.queryIds.count, 0)
    }

    func testSuccessfulDeclineClearsRequestTracking() throws {
        let manager = GroupchatManager(withOwner: owner)
        let stream = XMPPStream()
        manager.decline(stream, groupchat: "group@example.com") { _ in }
        let elementId = manager.queryIds.last ?? ""

        let iq = try makeIQ(xml: """
        <iq type='result' from='group@example.com' id='\(elementId)'/>
        """)

        XCTAssertTrue(manager.read(stream, withIQ: iq))
        XCTAssertEqual(manager.queryIds.count, 0)
        XCTAssertEqual(queueItemCount(in: manager), 0)
    }
}

final class MessageRoutingRegressionTests: XCTestCase {

    func testGroupOutboundDestinationJIDUsesBareJID() {
        let jid = MessageManager.outboundDestinationJID(
            for: "group@example.com",
            conversationType: .group,
            resource: "Group"
        )

        XCTAssertEqual(jid?.bare, "group@example.com")
        XCTAssertNil(jid?.resource)
    }

    func testRegularOutboundDestinationJIDKeepsResolvedResource() {
        let jid = MessageManager.outboundDestinationJID(
            for: "romeo@example.com",
            conversationType: .regular,
            resource: "iPhone"
        )

        XCTAssertEqual(jid?.bare, "romeo@example.com")
        XCTAssertEqual(jid?.resource, "iPhone")
    }
}

final class MessageDeleteManagerRegressionTests: XCTestCase {

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "MessageDeleteManagerRegressionTests", code: 1)
        }
        return root
    }

    private func makeIQ(xml: String) throws -> XMPPIQ {
        XMPPIQ(from: try makeElement(xml: xml))
    }

    func testSuccessfulDeleteReadClearsQueryTracking() throws {
        let manager = MessageDeleteManager(withOwner: "owner@example.com")
        let elementId = "RRR: success"

        manager.queryIds.insert(elementId)
        manager.itemsQuery.insert(
            MessageDeleteManager.Item(
                "",
                kind: .retract,
                messageId: "message-1",
                iqId: elementId,
                callback: nil
            )
        )

        let iq = try makeIQ(xml: """
        <iq type='result' id='\(elementId)'/>
        """)

        XCTAssertTrue(manager.read(withIQ: iq))
        XCTAssertEqual(manager.queryIds.count, 0)
        XCTAssertEqual(manager.itemsQuery.count, 0)
    }
}

final class GroupchatNicknamePresentationRegressionTests: XCTestCase {

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "GroupchatNicknamePresentationRegressionTests", code: 1)
        }
        return root
    }

    private func makeMessage(xml: String) throws -> XMPPMessage {
        XMPPMessage(from: try makeElement(xml: xml))
    }

    func testGroupchatUserElementSupportsDirectV3User() throws {
        let message = try makeMessage(xml: """
        <message type='chat' from='group@example.com/Group' to='owner@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='user-1'>
              <nickname>Ivan</nickname>
            </user>
          </x>
          <body>Ivan:
        hello</body>
        </message>
        """)

        let user = try XCTUnwrap(groupchatUserElement(from: message))
        XCTAssertEqual(user.attributeStringValue(forName: "id"), "user-1")
        XCTAssertEqual(user.element(forName: "nickname")?.stringValue, "Ivan")
    }

    func testGroupchatUserElementSupportsWrappedLegacyUserReference() throws {
        let message = try makeMessage(xml: """
        <message type='chat' from='group@example.com/Group' to='owner@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='6'>
              <user xmlns='https://xabber.com/protocol/groups' id='user-1'>
                <nickname>Ivan</nickname>
              </user>
            </reference>
          </x>
          <body>Ivan:
        hello</body>
        </message>
        """)

        let user = try XCTUnwrap(groupchatUserElement(from: message))
        XCTAssertEqual(user.attributeStringValue(forName: "id"), "user-1")
        XCTAssertEqual(user.element(forName: "nickname")?.stringValue, "Ivan")
    }

    func testConfigureIncomingMessageStripsDirectUserFallbackPrefix() throws {
        let message = try makeMessage(xml: """
        <message type='chat' from='group@example.com/Group' to='owner@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='user-1'>
              <nickname>Ivan</nickname>
            </user>
          </x>
          <body>Ivan:
        hello</body>
        </message>
        """)
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: "owner@example.com",
            opponent: "group@example.com",
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(item.body, "hello")
        XCTAssertEqual(item.legacyBody, "Ivan:\nhello")
        XCTAssertEqual(item.groupchatAuthorNickname, "Ivan")
    }

    func testConfigureIncomingMessageKeepsBodyWhenPrefixDoesNotMatchResolvedNickname() throws {
        let message = try makeMessage(xml: """
        <message type='chat' from='group@example.com/Group' to='owner@example.com'>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='user-1'>
              <nickname>Ivan</nickname>
            </user>
          </x>
          <body>Petr:
        hello</body>
        </message>
        """)
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: "owner@example.com",
            opponent: "group@example.com",
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(item.body, "Petr:\nhello")
        XCTAssertEqual(item.legacyBody, "Petr:\nhello")
        XCTAssertEqual(item.groupchatAuthorNickname, "Ivan")
    }

    func testConfigureIncomingMessageElidesAnonymousMutableFallbackRangeAndShiftsMentionOffsets() throws {
        let message = try makeMessage(xml: """
        <message xmlns='jabber:client' lang='en' to='public-group@seed.xabber.org' from='public-group@seed.xabber.org' type='chat' id='be6ea1705b4a6ecf'>
          <reference xmlns='https://xabber.com/protocol/references' end='7' begin='0' type='mutable'/>
          <x xmlns='https://xabber.com/protocol/groups'>
            <user id='3crotuldccvzsrif'>
              <role>member</role>
              <nickname>Heidi</nickname>
              <badge/>
              <jid>heidi@seed.xabber.org</jid>
            </user>
          </x>
          <reference xmlns='https://xabber.com/protocol/references' end='24' begin='7' type='decoration'>
            <link xmlns='https://xabber.com/protocol/markup'>xmpp:public-group@seed.xabber.org?members;id=0oud1rprz9ayy4kd</link>
          </reference>
          <markable xmlns='urn:xmpp:chat-markers:0'/>
          <origin-id xmlns='urn:xmpp:sid:0' id='be6ea1705b4a6ecf'/>
          <body>Heidi:
        alice@seed.xabber.org mention #2287</body>
        </message>
        """)
        let item = MessageStorageItem()

        item.configureIncomingMessage(
            message,
            owner: "owner@example.com",
            opponent: "public-group@seed.xabber.org",
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(item.body, "alice@seed.xabber.org mention #2287")
        XCTAssertEqual(item.legacyBody, "Heidi:\nalice@seed.xabber.org mention #2287")
        XCTAssertEqual(item.groupchatAuthorNickname, "Heidi")

        let mention = try XCTUnwrap(item.references.first(where: { $0.kind == .mention }))
        XCTAssertEqual(mention.begin, 0)
        XCTAssertEqual(mention.end, 17)
    }

    func testParseReferencesIgnoresInvalidAnonymousMutableRanges() throws {
        let message = try makeMessage(xml: """
        <message type='chat' from='group@example.com/Group' to='owner@example.com'>
          <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='20' end='40'/>
          <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='0' end='5'>
            <link xmlns='https://xabber.com/protocol/markup'>xmpp:group@example.com?members;id=user-1</link>
          </reference>
          <body>hello</body>
        </message>
        """)
        let references = parseReferences(
            message,
            primary: "test-primary",
            jid: "group@example.com",
            owner: "owner@example.com"
        )

        let mention = try XCTUnwrap(references.first(where: { $0.kind == .mention }))
        XCTAssertEqual(mention.begin, 0)
        XCTAssertEqual(mention.end, 5)

        let item = MessageStorageItem()
        item.configureIncomingMessage(
            message,
            owner: "owner@example.com",
            opponent: "group@example.com",
            outgoing: false,
            isRead: false,
            date: Date(timeIntervalSince1970: 10)
        )

        XCTAssertEqual(item.body, "hello")
    }
}

final class FavoritesFeatureTests: XCTestCase {

    private let owner = "igor.boldin@xmppdev01.xabber.com"

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "FavoritesFeatureTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    private func makeElement(xml: String) throws -> DDXMLElement {
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        guard let root = document.rootElement() else {
            throw NSError(domain: "FavoritesFeatureTests", code: 1)
        }
        return root
    }

    func testFavoritesDiscoRequiresArchiveIdentityAndFeature() throws {
        let validQuery = try makeElement(xml: """
        <query xmlns='http://jabber.org/protocol/disco#info'>
          <identity category='component' type='archive' name='Saved messages'/>
          <feature var='urn:xabber:favorites:0'/>
        </query>
        """)

        let missingFeatureQuery = try makeElement(xml: """
        <query xmlns='http://jabber.org/protocol/disco#info'>
          <identity category='component' type='archive' name='Saved messages'/>
        </query>
        """)

        XCTAssertTrue(XMPPFavoritesManager.supportsService(validQuery))
        XCTAssertFalse(XMPPFavoritesManager.supportsService(missingFeatureQuery))
    }

    func testIgnoredServiceJidsIncludeFavoritesNode() throws {
        let realm = try WRealm.safe()
        try realm.write {
            let abuse = XMPPAbuseConfigStorageItem()
            abuse.primary = "abuse"
            abuse.owner = owner
            abuse.abuseAddress = "abuse.xmppdev01.xabber.com"
            realm.add(abuse)
        }

        let ignored = XMPPServiceJidsSupport.ignoredServiceJids(
            in: realm,
            accountJids: [owner],
            serviceNodes: ["favorites.xmppdev01.xabber.com", "notifications.xmppdev01.xabber.com"]
        )

        XCTAssertTrue(ignored.contains(owner))
        XCTAssertTrue(ignored.contains("favorites.xmppdev01.xabber.com"))
        XCTAssertTrue(ignored.contains("notifications.xmppdev01.xabber.com"))
        XCTAssertTrue(ignored.contains("abuse.xmppdev01.xabber.com"))
    }

    func testBuildForwardMessageTargetsFavoritesNodeAndAddsForwardReference() throws {
        let realm = try WRealm.safe()
        let forwardedPrimary = "forwarded-message-primary"
        let stanzaPrimary = [forwardedPrimary, "stanza"].prp()
        try realm.write {
            let stanza = MessageStanzaStorageItem()
            stanza.primary = stanzaPrimary
            stanza.timestamp = ISO8601DateFormatter().date(from: "2026-03-24T12:34:56Z")!
            stanza.stanza = """
            <message from='romeo@xmppdev01.xabber.com/orchard' to='juliet@xmppdev01.xabber.com/balcony' type='chat' id='msg-1'>
              <body>Hello Juliet</body>
            </message>
            """
            realm.add(stanza)
        }

        let manager = XMPPFavoritesManager(withOwner: owner)
        manager.node = "favorites.xmppdev01.xabber.com"

        let stanza = manager.buildForwardMessage(for: [forwardedPrimary])

        XCTAssertEqual(stanza?.to?.bare, "favorites.xmppdev01.xabber.com")
        XCTAssertEqual(stanza?.type, "chat")
        XCTAssertNotNil(stanza?.body)
        let reference = stanza?.element(forName: "reference")
        XCTAssertNotNil(reference)
        XCTAssertEqual(reference?.xmlns(), "https://xabber.com/protocol/references")
        XCTAssertEqual(reference?.attributeStringValue(forName: "type"), "mutable")
        XCTAssertNotNil(reference?.element(forName: "forwarded"))
    }
}

final class ComposerMentionsTests: XCTestCase {

    private func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: UIColor.label
        ]
    }

    private func mentionAttributes(for entity: ComposerMentionEntity) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes()
        attributes[.composerMention] = entity
        attributes[.foregroundColor] = UIColor.systemBlue
        return attributes
    }

    func testMentionTriggerDetectionFindsActiveQuery() {
        let text = NSAttributedString(string: "Hello @Sha", attributes: baseAttributes())

        let query = ComposerMentionQueryDetector.activeQuery(
            in: text,
            selectedRange: NSRange(location: text.length, length: 0)
        )

        XCTAssertEqual(query?.query, "Sha")
        XCTAssertEqual(query?.triggerRange, NSRange(location: 6, length: 1))
        XCTAssertEqual(query?.replacementRange, NSRange(location: 6, length: 4))
    }

    func testMentionTriggerDetectionSupportsBareAtSymbol() {
        let text = NSAttributedString(string: "@", attributes: baseAttributes())

        let query = ComposerMentionQueryDetector.activeQuery(
            in: text,
            selectedRange: NSRange(location: text.length, length: 0)
        )

        XCTAssertEqual(query?.query, "")
        XCTAssertEqual(query?.triggerRange, NSRange(location: 0, length: 1))
        XCTAssertEqual(query?.replacementRange, NSRange(location: 0, length: 1))
    }

    func testInsertMentionAddsDecoratedTokenAndTrailingSpace() {
        let text = NSAttributedString(string: "Hello @sh", attributes: baseAttributes())
        let entity = ComposerMentionEntity(
            memberId: "123333",
            nickname: "Shadow_of_my_moon",
            uri: "xmpp:trio@example.com?members;id=123333",
            node: "https://xabber.com/protocol/groupchat",
            jid: "shadow@example.com"
        )

        let result = ComposerMentionEditor.insertMention(
            in: text,
            replacementRange: NSRange(location: 6, length: 3),
            entity: entity,
            baseAttributes: baseAttributes(),
            mentionAttributes: mentionAttributes(for: entity)
        )

        XCTAssertEqual(result.attributedText.string, "Hello Shadow_of_my_moon ")
        XCTAssertEqual(result.selectedRange.location, result.attributedText.length)
        XCTAssertEqual(ComposerMentionEditor.mentionRanges(in: result.attributedText), [NSRange(location: 6, length: 17)])
    }

    func testEditingInsideMentionRemovesWholeMentionEntity() {
        let entity = ComposerMentionEntity(
            memberId: "123333",
            nickname: "Shadow",
            uri: "xmpp:trio@example.com?members;id=123333",
            node: "https://xabber.com/protocol/groupchat",
            jid: "shadow@example.com"
        )
        let attributed = NSMutableAttributedString(string: "Hello ", attributes: baseAttributes())
        attributed.append(NSAttributedString(string: "Shadow", attributes: mentionAttributes(for: entity)))
        attributed.append(NSAttributedString(string: " world", attributes: baseAttributes()))

        let mutation = ComposerMentionEditor.mutationForEditing(
            attributedText: attributed,
            range: NSRange(location: 8, length: 1),
            replacementText: "",
            baseAttributes: baseAttributes()
        )

        XCTAssertEqual(mutation?.attributedText.string, "Hello  world")
        XCTAssertTrue(ComposerMentionEditor.mentionRanges(in: mutation?.attributedText ?? NSAttributedString()).isEmpty)
    }

    func testMentionPayloadUsesEscapedOffsets() {
        let entity = ComposerMentionEntity(
            memberId: "123333",
            nickname: "Shadow",
            uri: "xmpp:trio@example.com?members;id=123333",
            node: "https://xabber.com/protocol/groupchat",
            jid: "shadow@example.com"
        )
        let attributed = NSMutableAttributedString(string: "A & B ", attributes: baseAttributes())
        attributed.append(NSAttributedString(string: "Shadow", attributes: mentionAttributes(for: entity)))

        let payload = ComposerMentionSerializer.payload(from: attributed)

        XCTAssertEqual(payload.body, "A & B Shadow")
        XCTAssertEqual(payload.references.count, 1)
        XCTAssertEqual(payload.references.first?.begin, 10)
        XCTAssertEqual(payload.references.first?.end, 16)
        XCTAssertEqual(payload.references.first?.kind, .mention)
        XCTAssertEqual(payload.references.first?.metadata?["uri"] as? String, "xmpp:trio@example.com?members;id=123333")
    }

    func testChatBubbleMentionRenderingUsesTintedLinkWithoutFilledBackground() {
        let reference = MessageReferenceStorageItem()
        reference.kind = .mention
        reference.begin = 6
        reference.end = 13
        reference.metadata = [
            "uri": "xmpp:trio@example.com?members;id=123333",
            "node": "https://xabber.com/protocol/groupchat",
            "memberId": "123333",
            "nickname": "@Shadow"
        ]

        let item = MessageStorageItem()
        item.body = "Hello @Shadow"
        item.owner = "owner@example.com"
        item.references.append(reference)

        let attributed = item.createRefBody(baseAttributes())
        let mentionRange = NSRange(location: 6, length: 7)

        XCTAssertEqual(
            attributed.attribute(.link, at: mentionRange.location, effectiveRange: nil) as? String,
            "xmpp:trio@example.com?members;id=123333"
        )
        XCTAssertNotNil(attributed.attribute(.foregroundColor, at: mentionRange.location, effectiveRange: nil))
        XCTAssertNil(attributed.attribute(.backgroundColor, at: mentionRange.location, effectiveRange: nil))
    }

    func testCreateReferencesBuildsWebGroupMentionDecorationXml() {
        let reference = MessageReferenceStorageItem()
        reference.kind = .mention
        reference.begin = 6
        reference.end = 13
        reference.metadata = [
            "uri": "xmpp:trio@example.com?members;id=123333",
            "node": "https://xabber.com/protocol/groupchat",
            "memberId": "123333",
            "nickname": "@Shadow"
        ]

        let item = MessageStorageItem()
        item.body = "Hello @Shadow"
        item.owner = "owner@example.com"
        item.references.append(reference)

        let xml = item.createReferences()

        XCTAssertEqual(xml.count, 1)
        XCTAssertEqual(xml.first?.attributeStringValue(forName: "type"), "decoration")
        XCTAssertNil(xml.first?.element(forName: "mention", xmlns: "https://xabber.com/protocol/markup"))
        XCTAssertEqual(xml.first?.element(forName: "link", xmlns: "https://xabber.com/protocol/markup")?.stringValue, "xmpp:trio@example.com?members;id=123333")
    }

    func testCreateMentionsElementBuildsWebGroupMentionsXml() {
        let firstReference = MessageReferenceStorageItem()
        firstReference.kind = .mention
        firstReference.metadata = [
            "uri": "xmpp:trio@example.com?members;id=123333",
            "memberId": "123333"
        ]

        let duplicateReference = MessageReferenceStorageItem()
        duplicateReference.kind = .mention
        duplicateReference.metadata = [
            "uri": "xmpp:trio@example.com?members;id=123333"
        ]

        let item = MessageStorageItem()
        item.references.append(firstReference)
        item.references.append(duplicateReference)

        let mentions = item.createMentionsElement()

        XCTAssertEqual(mentions?.name, "mentions")
        XCTAssertEqual(mentions?.xmlns(), "https://xabber.com/protocol/groups")
        XCTAssertEqual(mentions?.elements(forName: "user").count, 1)
        XCTAssertEqual(mentions?.element(forName: "user")?.attributeStringValue(forName: "id"), "123333")
    }

    func testParseReferencesSupportsCanonicalMentionElement() throws {
        let xml = """
        <message type='groupchat' from='trio@example.com' to='owner@example.com'>
          <body>Hello @Shadow</body>
          <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='6' end='13'>
            <mention xmlns='https://xabber.com/protocol/markup' node='https://xabber.com/protocol/groupchat'>xmpp:trio@example.com?id=123333</mention>
          </reference>
        </message>
        """
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        let root = try XCTUnwrap(document.rootElement())
        let message = XMPPMessage(from: root)

        let references = parseReferences(message, primary: "test-primary", jid: "trio@example.com", owner: "owner@example.com")
        let first = try XCTUnwrap(references.first)

        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(first.kind, .mention)
        XCTAssertEqual(first.begin, 6)
        XCTAssertEqual(first.end, 13)
        XCTAssertEqual(first.metadata?["uri"] as? String, "xmpp:trio@example.com?id=123333")
        XCTAssertEqual(first.metadata?["node"] as? String, "https://xabber.com/protocol/groupchat")
        XCTAssertEqual(first.metadata?["nickname"] as? String, "@Shadow")
    }

    func testParseReferencesSupportsWebClientGroupMentionStanza() throws {
        let xml = """
        <message id='7c47df87-42f4-438d-8fde-636a084afbfd' to='ios-mentions-group-test-01@redsolution.com' type='chat' xmlns='jabber:client'>
          <mentions xmlns='https://xabber.com/protocol/groups'>
            <user id='ck9akic0tlytovth'/>
          </mentions>
          <reference begin='0' end='9' type='decoration' xmlns='https://xabber.com/protocol/references'>
            <link xmlns='https://xabber.com/protocol/markup'>xmpp:ios-mentions-group-test-01@redsolution.com?members;id=ck9akic0tlytovth</link>
          </reference>
          <body>test nick</body>
        </message>
        """
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        let root = try XCTUnwrap(document.rootElement())
        let message = XMPPMessage(from: root)

        let references = parseReferences(message, primary: "test-primary", jid: "ios-mentions-group-test-01@redsolution.com", owner: "owner@example.com")
        let first = try XCTUnwrap(references.first)

        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(first.kind, .mention)
        XCTAssertEqual(first.metadata?["uri"] as? String, "xmpp:ios-mentions-group-test-01@redsolution.com?members;id=ck9akic0tlytovth")
        XCTAssertEqual(first.metadata?["memberId"] as? String, "ck9akic0tlytovth")
        XCTAssertEqual(first.metadata?["groupchatJid"] as? String, "ios-mentions-group-test-01@redsolution.com")
        XCTAssertEqual(first.metadata?["nickname"] as? String, "test nick")
    }

    func testParseReferencesSupportsLegacyXmppLinkMentions() throws {
        let xml = """
        <message type='groupchat' from='trio@example.com' to='owner@example.com'>
          <body>Hello @Shadow</body>
          <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='6' end='13'>
            <link xmlns='https://xabber.com/protocol/markup'>xmpp:trio@example.com?id=123333</link>
          </reference>
        </message>
        """
        let document = try DDXMLDocument(xmlString: xml, options: 0)
        let root = try XCTUnwrap(document.rootElement())
        let message = XMPPMessage(from: root)

        let references = parseReferences(message, primary: "test-primary", jid: "trio@example.com", owner: "owner@example.com")
        let first = try XCTUnwrap(references.first)

        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(first.kind, .mention)
        XCTAssertEqual(first.metadata?["memberId"] as? String, "123333")
        XCTAssertEqual(first.metadata?["groupchatJid"] as? String, "trio@example.com")
    }

    func testDeserializeMentionReferencesBackIntoDecoratedEditorState() {
        let reference = MessageReferenceStorageItem()
        reference.kind = .mention
        reference.begin = 6
        reference.end = 13
        reference.metadata = [
            "uri": "xmpp:trio@example.com?members;id=123333",
            "node": "https://xabber.com/protocol/groupchat",
            "nickname": "@Shadow"
        ]

        let attributed = ComposerMentionSerializer.attributedText(
            body: "Hello @Shadow",
            references: [reference],
            baseAttributes: baseAttributes(),
            mentionAttributesProvider: { [self] entity in
                self.mentionAttributes(for: entity)
            }
        )

        XCTAssertEqual(attributed.string, "Hello @Shadow")
        let ranges = ComposerMentionEditor.mentionRanges(in: attributed)
        XCTAssertEqual(ranges, [NSRange(location: 6, length: 7)])
        let entity = attributed.attribute(.composerMention, at: 6, effectiveRange: nil) as? ComposerMentionEntity
        XCTAssertEqual(entity?.memberId, "123333")
        XCTAssertEqual(entity?.uri, "xmpp:trio@example.com?members;id=123333")
    }

    func testDeserializeMentionReferencesUsesEscapedOffsets() {
        let reference = MessageReferenceStorageItem()
        reference.kind = .mention
        reference.begin = 10
        reference.end = 17
        reference.metadata = [
            "uri": "xmpp:trio@example.com?members;id=123333",
            "node": "https://xabber.com/protocol/groupchat",
            "nickname": "@Shadow"
        ]

        let attributed = ComposerMentionSerializer.attributedText(
            body: "A & B @Shadow",
            references: [reference],
            baseAttributes: baseAttributes(),
            mentionAttributesProvider: { [self] entity in
                self.mentionAttributes(for: entity)
            }
        )

        XCTAssertEqual(ComposerMentionEditor.mentionRanges(in: attributed), [NSRange(location: 6, length: 7)])
    }

    func testMentionPayloadCoalescesSplitMentionRuns() {
        let entity = ComposerMentionEntity(
            memberId: "123333",
            nickname: "Shadow",
            uri: "xmpp:trio@example.com?members;id=123333",
            node: "https://xabber.com/protocol/groupchat",
            jid: "shadow@example.com"
        )
        let attributed = NSMutableAttributedString(string: "Hello ", attributes: baseAttributes())
        attributed.append(NSAttributedString(string: "Sha", attributes: mentionAttributes(for: entity)))
        attributed.append(NSAttributedString(string: "dow", attributes: mentionAttributes(for: entity)))

        let payload = ComposerMentionSerializer.payload(from: attributed)

        XCTAssertEqual(payload.references.count, 1)
        XCTAssertEqual(payload.references.first?.begin, 6)
        XCTAssertEqual(payload.references.first?.end, 12)
        XCTAssertEqual(payload.references.first?.metadata?["nickname"] as? String, "Shadow")
    }

    func testDeletingAtMentionBoundaryRemovesWholeMentionEntity() {
        let entity = ComposerMentionEntity(
            memberId: "123333",
            nickname: "Shadow",
            uri: "xmpp:trio@example.com?members;id=123333",
            node: "https://xabber.com/protocol/groupchat",
            jid: "shadow@example.com"
        )
        let attributed = NSMutableAttributedString(string: "Hello ", attributes: baseAttributes())
        attributed.append(NSAttributedString(string: "Shadow", attributes: mentionAttributes(for: entity)))
        attributed.append(NSAttributedString(string: " world", attributes: baseAttributes()))

        let mutation = ComposerMentionEditor.mutationForEditing(
            attributedText: attributed,
            range: NSRange(location: 12, length: 0),
            replacementText: "",
            baseAttributes: baseAttributes()
        )

        XCTAssertEqual(mutation?.attributedText.string, "Hello  world")
        XCTAssertTrue(ComposerMentionEditor.mentionRanges(in: mutation?.attributedText ?? NSAttributedString()).isEmpty)
    }

    func testMentionPanelHitTestingWorksOutsideComposerBounds() {
        let inputView = ModernXabberInputView(frame: CGRect(x: 0, y: 0, width: 390, height: 49))
        inputView.mentionPanel.isHidden = false
        inputView.mentionPanel.frame = CGRect(x: 40, y: -112, width: 306, height: 104)
        inputView.layoutIfNeeded()

        let point = CGPoint(x: 195, y: -60)

        XCTAssertTrue(inputView.point(inside: point, with: nil))
        let hitView = inputView.hitTest(point, with: nil)
        XCTAssertNotNil(hitView)
        XCTAssertTrue(hitView === inputView.mentionPanel || hitView?.isDescendant(of: inputView.mentionPanel) == true)
    }
}

final class ChatUnreadMentionsTests: XCTestCase {

    private let owner = "owner@example.com"
    private let groupchatJid = "trio@example.com"
    private let currentMemberId = "me-1"

    override func setUpWithError() throws {
        let realm = try WRealm.safe()
        try realm.write {
            realm.objects(MessageStorageItem.self)
                .filter("owner == %@", owner)
                .forEach { realm.delete($0) }
            realm.objects(NotificationStorageItem.self)
                .filter("owner == %@", owner)
                .forEach { realm.delete($0) }
            realm.objects(LastChatsStorageItem.self)
                .filter("owner == %@", owner)
                .forEach { realm.delete($0) }
            realm.objects(GroupchatUserStorageItem.self)
                .filter("owner == %@", owner)
                .forEach { realm.delete($0) }
        }
    }

    private func insertLastChat(
        jid: String? = nil,
        conversationType: ClientSynchronizationManager.ConversationType = .group
    ) throws {
        let jid = jid ?? groupchatJid
        let realm = try WRealm.safe()
        let chat = LastChatsStorageItem()
        chat.owner = owner
        chat.jid = jid
        chat.conversationType = conversationType
        chat.primary = LastChatsStorageItem.genPrimary(jid: jid, owner: owner, conversationType: conversationType)
        chat.groupchatMyId = currentMemberId

        try realm.write {
            realm.add(chat, update: .modified)
        }
    }

    private func insertMyGroupUser(
        jid: String? = nil,
        userId: String? = nil,
        isHidden: Bool = false
    ) throws {
        let jid = jid ?? groupchatJid
        let userId = userId ?? currentMemberId
        let realm = try WRealm.safe()
        let member = GroupchatUserStorageItem()
        member.owner = owner
        member.userId = userId
        member.jid = owner
        member.groupchatId = [jid, owner].prp()
        member.primary = GroupchatUserStorageItem.genPrimary(id: userId, groupchat: jid, owner: owner)
        member.isMe = true
        member.isHidden = isHidden

        try realm.write {
            realm.add(member, update: .modified)
        }
    }

    private func makeReference(
        kind: MessageReferenceStorageItem.Kind,
        metadata: [String: Any]
    ) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.kind = kind
        reference.metadata = metadata
        return reference
    }

    private func makeMessage(
        primary: String,
        archivedId: String,
        messageId: String = "",
        authorId: String,
        isRead: Bool = false,
        isDeleted: Bool = false,
        mentionMemberIds: [String] = [],
        date: Date
    ) -> MessageStorageItem {
        let message = MessageStorageItem()
        message.primary = primary
        message.archivedId = archivedId
        message.owner = owner
        message.opponent = groupchatJid
        message.body = mentionMemberIds.isEmpty ? "Hello" : "Hello @you"
        message.displayAs = .text
        message.conversationType = .group
        message.isRead = isRead
        message.isDeleted = isDeleted
        message.outgoing = false
        message.messageId = messageId
        message.date = date
        message.sentDate = date

        let authorReference = makeReference(
            kind: .groupchat,
            metadata: [
                "id": authorId,
                "nickname": "Author \(authorId)"
            ]
        )
        message.references.append(authorReference)

        mentionMemberIds.forEach { memberId in
            let mentionReference = makeReference(
                kind: .mention,
                metadata: [
                    "uri": "xmpp:\(groupchatJid)?members;id=\(memberId)",
                    "memberId": memberId,
                    "groupchatJid": groupchatJid,
                    "nickname": "@\(memberId)"
                ]
            )
            message.references.append(mentionReference)
        }

        return message
    }

    private func makeMentionNotification(
        primary: String,
        archivedId: String? = nil,
        messageId: String? = nil,
        authorId: String = "other-1",
        targetMemberId: String? = nil,
        isRead: Bool = false,
        linkStatus: NotificationStorageItem.MentionLinkStatus? = .resolved,
        conversationType: ClientSynchronizationManager.ConversationType? = .group,
        sourceChatJid: String? = nil,
        date: Date
    ) -> NotificationStorageItem {
        let notification = NotificationStorageItem()
        notification.primary = primary
        notification.owner = owner
        notification.category = .mention
        notification.isRead = isRead
        notification.sourceConversationType = conversationType
        notification.sourceChatJid = sourceChatJid ?? groupchatJid
        notification.sourceArchivedId = archivedId
        notification.sourceMessageId = messageId
        notification.sourceSenderId = authorId
        notification.mentionTargetUserId = targetMemberId ?? currentMemberId
        notification.sourceMessageDate = date
        notification.mentionLinkStatus = linkStatus
        return notification
    }

    func testUnreadMentionMatcherUsesUnreadNotificationStateInsteadOfMessageReadState() throws {
        let message = makeMessage(
            primary: "m1",
            archivedId: "a1",
            messageId: "mid-1",
            authorId: "other-1",
            isRead: true,
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            messageId: "mid-1",
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(message, update: .modified)
            realm.add(notification, update: .modified)
        }

        let messages = realm.objects(MessageStorageItem.self)
            .filter("owner == %@ AND opponent == %@", owner, groupchatJid)

        let item = ChatUnreadMentionMatcher.unreadMentionItem(
            from: notification,
            messagesObserver: messages,
            observerLookupMaps: ChatObserverLookupPolicy.build(from: messages),
            in: realm,
            chatPrimary: "chat-1",
            currentMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )

        XCTAssertEqual(item?.notificationPrimary, "n1")
        XCTAssertEqual(item?.messagePrimary, "m1")
        XCTAssertEqual(item?.archivedId, "a1")
        XCTAssertEqual(item?.targetMemberId, currentMemberId)
        XCTAssertEqual(item?.groupchatJid, groupchatJid)
        XCTAssertTrue(
            ChatUnreadMentionFloatingControlPolicy.shouldShowNavigator(
                conversationType: .group,
                unreadCount: item == nil ? 0 : 1,
                isSearchMode: false
            )
        )
    }

    func testCurrentGroupMemberIdUsesCompositeGroupchatStorageKey() throws {
        try insertMyGroupUser()
        let realm = try WRealm.safe()

        XCTAssertEqual(
            MentionNotificationSync.currentGroupMemberId(
                owner: owner,
                groupchatJid: groupchatJid,
                in: realm
            ),
            currentMemberId
        )
    }

    func testUnreadMentionMatcherUsesCanonicalCurrentMemberIdWhenNotificationTargetIsMissing() throws {
        try insertMyGroupUser()
        let message = makeMessage(
            primary: "m1",
            archivedId: "a1",
            messageId: "mid-1",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            messageId: "mid-1",
            date: Date(timeIntervalSince1970: 10)
        )
        notification.mentionTargetUserId = nil
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(message, update: .modified)
            realm.add(notification, update: .modified)
        }

        let messages = realm.objects(MessageStorageItem.self)
            .filter("owner == %@ AND opponent == %@", owner, groupchatJid)

        let item = ChatUnreadMentionMatcher.unreadMentionItem(
            from: notification,
            messagesObserver: messages,
            observerLookupMaps: ChatObserverLookupPolicy.build(from: messages),
            in: realm,
            chatPrimary: "chat-1",
            currentMemberId: MentionNotificationSync.currentGroupMemberId(
                owner: owner,
                groupchatJid: groupchatJid,
                in: realm
            ),
            groupchatJid: groupchatJid
        )

        XCTAssertEqual(item?.notificationPrimary, "n1")
        XCTAssertEqual(item?.targetMemberId, currentMemberId)
    }

    func testUnreadMentionMatcherKeepsUnreadNotificationWhenTargetMemberIsUnresolved() throws {
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            messageId: "mid-1",
            targetMemberId: nil,
            date: Date(timeIntervalSince1970: 10)
        )
        notification.mentionTargetUserId = nil
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(notification, update: .modified)
        }

        let messages = realm.objects(MessageStorageItem.self)
            .filter("owner == %@ AND opponent == %@", owner, groupchatJid)

        let item = ChatUnreadMentionMatcher.unreadMentionItem(
            from: notification,
            messagesObserver: messages,
            observerLookupMaps: ChatObserverLookupPolicy.build(from: messages),
            in: realm,
            chatPrimary: "chat-1",
            currentMemberId: nil,
            groupchatJid: groupchatJid
        )

        XCTAssertEqual(item?.notificationPrimary, "n1")
        XCTAssertNil(item?.targetMemberId)
        XCTAssertNil(item?.messagePrimary)
        XCTAssertEqual(item?.archivedId, "a1")
        XCTAssertTrue(
            ChatUnreadMentionFloatingControlPolicy.shouldShowNavigator(
                conversationType: .group,
                unreadCount: item == nil ? 0 : 1,
                isSearchMode: false
            )
        )
    }

    func testUnreadMentionMatcherSkipsKnownSelfAuthoredMention() throws {
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            messageId: "mid-1",
            authorId: currentMemberId,
            targetMemberId: currentMemberId,
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(notification, update: .modified)
        }

        let messages = realm.objects(MessageStorageItem.self)
            .filter("owner == %@ AND opponent == %@", owner, groupchatJid)

        let item = ChatUnreadMentionMatcher.unreadMentionItem(
            from: notification,
            messagesObserver: messages,
            observerLookupMaps: ChatObserverLookupPolicy.build(from: messages),
            in: realm,
            chatPrimary: "chat-1",
            currentMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )

        XCTAssertNil(item)
    }

    func testUnreadMentionMatcherSkipsInvalidatedNotification() throws {
        let message = makeMessage(
            primary: "m1",
            archivedId: "a1",
            messageId: "mid-1",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            messageId: "mid-1",
            linkStatus: .invalidated,
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(message, update: .modified)
            realm.add(notification, update: .modified)
        }

        let messages = realm.objects(MessageStorageItem.self)
            .filter("owner == %@ AND opponent == %@", owner, groupchatJid)

        let item = ChatUnreadMentionMatcher.unreadMentionItem(
            from: notification,
            messagesObserver: messages,
            observerLookupMaps: ChatObserverLookupPolicy.build(from: messages),
            in: realm,
            chatPrimary: "chat-1",
            currentMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )

        XCTAssertNil(item)
    }

    func testUnreadMentionMatcherSkipsMissingNotification() throws {
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            messageId: "mid-1",
            linkStatus: .missing,
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(notification, update: .modified)
        }

        let messages = realm.objects(MessageStorageItem.self)
            .filter("owner == %@ AND opponent == %@", owner, groupchatJid)

        let item = ChatUnreadMentionMatcher.unreadMentionItem(
            from: notification,
            messagesObserver: messages,
            observerLookupMaps: ChatObserverLookupPolicy.build(from: messages),
            in: realm,
            chatPrimary: "chat-1",
            currentMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )

        XCTAssertNil(item)
    }

    func testUnreadMentionMatcherTrustsNotificationTargetUserIdWhenItDiffersFromCurrentMemberId() throws {
        let message = makeMessage(
            primary: "m1",
            archivedId: "a1",
            messageId: "mid-1",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            messageId: "mid-1",
            targetMemberId: "alice@seed.xabber.org",
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(message, update: .modified)
            realm.add(notification, update: .modified)
        }

        let messages = realm.objects(MessageStorageItem.self)
            .filter("owner == %@ AND opponent == %@", owner, groupchatJid)

        let item = ChatUnreadMentionMatcher.unreadMentionItem(
            from: notification,
            messagesObserver: messages,
            observerLookupMaps: ChatObserverLookupPolicy.build(from: messages),
            in: realm,
            chatPrimary: "chat-1",
            currentMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )

        XCTAssertEqual(item?.notificationPrimary, "n1")
        XCTAssertEqual(item?.targetMemberId, "alice@seed.xabber.org")
    }

    func testMatchingMessagePrefersArchivedIdOverMessageIdFallback() throws {
        let archivedMatch = makeMessage(
            primary: "m-archived",
            archivedId: "archived-hit",
            messageId: "message-other",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let messageIdMatch = makeMessage(
            primary: "m-message-id",
            archivedId: "archived-other",
            messageId: "message-hit",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(archivedMatch, update: .modified)
            realm.add(messageIdMatch, update: .modified)
        }

        let matched = MentionNotificationSync.matchingMessage(
            owner: owner,
            sourceChatJid: groupchatJid,
            conversationType: .group,
            sourceArchivedId: "archived-hit",
            sourceMessageId: "message-hit",
            sourceMessageDate: Date(timeIntervalSince1970: 10),
            sourceSenderId: "other-1",
            sourceBodyFingerprint: MentionNotificationSync.normalizedBodyFingerprint("Hello @you"),
            in: realm
        )

        XCTAssertEqual(matched?.primary, "m-archived")
    }

    func testMatchingMessageFallsBackToMessageIdWhenArchivedIdIsMissing() throws {
        let message = makeMessage(
            primary: "m-message-id",
            archivedId: "archived-other",
            messageId: "message-hit",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(message, update: .modified)
        }

        let matched = MentionNotificationSync.matchingMessage(
            owner: owner,
            sourceChatJid: groupchatJid,
            conversationType: .group,
            sourceArchivedId: nil,
            sourceMessageId: "message-hit",
            sourceMessageDate: Date(timeIntervalSince1970: 10),
            sourceSenderId: "other-1",
            sourceBodyFingerprint: MentionNotificationSync.normalizedBodyFingerprint("Hello @you"),
            in: realm
        )

        XCTAssertEqual(matched?.primary, "m-message-id")
    }

    func testMatchingMessageFallsBackToTimestampSenderAndBodyFingerprint() throws {
        let message = makeMessage(
            primary: "m-metadata",
            archivedId: "",
            messageId: "",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(message, update: .modified)
        }

        let matched = MentionNotificationSync.matchingMessage(
            owner: owner,
            sourceChatJid: groupchatJid,
            conversationType: .group,
            sourceArchivedId: nil,
            sourceMessageId: nil,
            sourceMessageDate: Date(timeIntervalSince1970: 10),
            sourceSenderId: "other-1",
            sourceBodyFingerprint: MentionNotificationSync.normalizedBodyFingerprint("Hello @you"),
            in: realm
        )

        XCTAssertEqual(matched?.primary, "m-metadata")
    }

    func testUnreadMentionIndexPolicyDeduplicatesDuplicateNotificationAnchors() throws {
        let message = makeMessage(
            primary: "m1",
            archivedId: "a1",
            messageId: "mid-1",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let firstNotification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            messageId: "mid-1",
            date: Date(timeIntervalSince1970: 10)
        )
        let secondNotification = makeMentionNotification(
            primary: "n2",
            archivedId: "a1",
            messageId: "mid-1",
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(message, update: .modified)
            realm.add(firstNotification, update: .modified)
            realm.add(secondNotification, update: .modified)
        }

        let notifications = realm.objects(NotificationStorageItem.self)
            .filter("owner == %@ AND category_ == %@", owner, XMPPNotificationsManager.Category.mention.rawValue)
        let messages = realm.objects(MessageStorageItem.self)
            .filter("owner == %@ AND opponent == %@", owner, groupchatJid)

        let items = ChatUnreadMentionIndexPolicy.rebuild(
            from: notifications,
            messagesObserver: messages,
            observerLookupMaps: ChatObserverLookupPolicy.build(from: messages),
            in: realm,
            chatPrimary: "chat-1",
            currentMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.messagePrimary, "m1")
    }

    func testUnreadMentionNavigationPolicyMarksVisibleMentionNotificationsAsVisibleUnread() {
        let first = ChatUnreadMentionItem(
            notificationPrimary: "n1",
            messagePrimary: "m1",
            archivedId: "a1",
            messageId: "mid-1",
            chatPrimary: "chat-1",
            authorId: "other-1",
            date: Date(timeIntervalSince1970: 10),
            targetMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )
        let second = ChatUnreadMentionItem(
            notificationPrimary: "n2",
            messagePrimary: "m2",
            archivedId: "a2",
            messageId: "mid-2",
            chatPrimary: "chat-1",
            authorId: "other-2",
            date: Date(timeIntervalSince1970: 20),
            targetMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )

        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: [first, second],
            observerPrimaryIndexMap: ["m1": 0, "m2": 2],
            visiblePrimaries: ["m2"]
        )

        XCTAssertEqual(state.unreadCount, 2)
        XCTAssertEqual(state.visibleUnreadNotificationPrimaries, ["n2"])
        XCTAssertEqual(state.currentTarget?.notificationPrimary, "n2")
    }

    func testUnreadMentionNavigationPolicyUsesSelectedNotificationAsCurrentAndJumpTarget() {
        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: [
                ChatUnreadMentionItem(notificationPrimary: "n1", messagePrimary: "m1", archivedId: "a1", messageId: "mid-1", chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 10), targetMemberId: currentMemberId, groupchatJid: groupchatJid),
                ChatUnreadMentionItem(notificationPrimary: "n2", messagePrimary: "m2", archivedId: "a2", messageId: "mid-2", chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 20), targetMemberId: currentMemberId, groupchatJid: groupchatJid),
                ChatUnreadMentionItem(notificationPrimary: "n3", messagePrimary: "m3", archivedId: "a3", messageId: "mid-3", chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 30), targetMemberId: currentMemberId, groupchatJid: groupchatJid)
            ],
            observerPrimaryIndexMap: ["m1": 0, "m2": 1, "m3": 2],
            visiblePrimaries: [],
            selectedNotificationPrimary: "n2"
        )

        XCTAssertEqual(state.currentTarget?.notificationPrimary, "n2")
        XCTAssertEqual(state.jumpTarget?.notificationPrimary, "n2")
    }

    func testUnreadMentionNavigationPolicyUsesPreferredArchivedIdAsInitialTargetHint() {
        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: [
                ChatUnreadMentionItem(notificationPrimary: "n1", messagePrimary: nil, archivedId: "a1", messageId: nil, chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 10), targetMemberId: currentMemberId, groupchatJid: groupchatJid),
                ChatUnreadMentionItem(notificationPrimary: "n2", messagePrimary: nil, archivedId: "a2", messageId: nil, chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 20), targetMemberId: currentMemberId, groupchatJid: groupchatJid)
            ],
            observerPrimaryIndexMap: [:],
            visiblePrimaries: [],
            preferredArchivedId: "a2"
        )

        XCTAssertEqual(state.currentTarget?.archivedId, "a2")
        XCTAssertEqual(state.jumpTarget?.archivedId, "a2")
    }

    func testLastChatMentionIdFallbackCreatesSingleUnreadMentionTarget() {
        let item = ChatUnreadMentionFallbackPolicy.fallbackItem(
            mentionId: "a-fallback",
            chatPrimary: "chat-1",
            currentMemberId: nil,
            groupchatJid: groupchatJid,
            date: Date(timeIntervalSince1970: 10)
        )
        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: item.map { [$0] } ?? [],
            observerPrimaryIndexMap: [:],
            visiblePrimaries: []
        )

        XCTAssertNil(item?.notificationPrimary)
        XCTAssertEqual(state.unreadCount, 1)
        XCTAssertEqual(state.currentTarget?.archivedId, "a-fallback")
        XCTAssertEqual(state.jumpTarget?.archivedId, "a-fallback")
        XCTAssertTrue(
            ChatUnreadMentionFloatingControlPolicy.shouldShowNavigator(
                conversationType: .group,
                unreadCount: state.unreadCount,
                isSearchMode: false
            )
        )
    }

    func testLastChatMentionIdFallbackDoesNotScheduleReadReconciliation() {
        let item = ChatUnreadMentionFallbackPolicy.fallbackItem(
            mentionId: "a-fallback",
            chatPrimary: "chat-1",
            currentMemberId: nil,
            groupchatJid: groupchatJid,
            date: Date(timeIntervalSince1970: 10)
        )
        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: item.map { [$0] } ?? [],
            observerPrimaryIndexMap: [:],
            visiblePrimaries: ["m1"]
        )

        XCTAssertNil(item?.notificationPrimary)
        XCTAssertTrue(state.visibleUnreadNotificationPrimaries.isEmpty)
    }

    func testUnreadMentionNavigationPolicySingleUnreadUsesIndicatorMode() {
        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: [
                ChatUnreadMentionItem(notificationPrimary: "n1", messagePrimary: "m1", archivedId: "a1", messageId: "mid-1", chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 10), targetMemberId: currentMemberId, groupchatJid: groupchatJid)
            ],
            observerPrimaryIndexMap: ["m1": 0],
            visiblePrimaries: []
        )

        XCTAssertEqual(state.mode, .indicator)
        XCTAssertEqual(state.jumpTarget?.notificationPrimary, "n1")
    }

    func testUnreadMentionNavigationPolicyUsesNextUnreadAfterVisibleTarget() {
        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: [
                ChatUnreadMentionItem(notificationPrimary: "n1", messagePrimary: "m1", archivedId: "a1", messageId: "mid-1", chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 10), targetMemberId: currentMemberId, groupchatJid: groupchatJid),
                ChatUnreadMentionItem(notificationPrimary: "n2", messagePrimary: "m2", archivedId: "a2", messageId: "mid-2", chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 20), targetMemberId: currentMemberId, groupchatJid: groupchatJid),
                ChatUnreadMentionItem(notificationPrimary: "n3", messagePrimary: "m3", archivedId: "a3", messageId: "mid-3", chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 30), targetMemberId: currentMemberId, groupchatJid: groupchatJid)
            ],
            observerPrimaryIndexMap: ["m1": 0, "m2": 1, "m3": 2],
            visiblePrimaries: ["m2"]
        )

        XCTAssertEqual(state.currentTarget?.notificationPrimary, "n2")
        XCTAssertEqual(state.jumpTarget?.notificationPrimary, "n3")
    }

    func testUnreadMentionNavigationPolicyDoesNotWrapAfterLastVisibleTarget() {
        let state = ChatUnreadMentionNavigationPolicy.resolveState(
            items: [
                ChatUnreadMentionItem(notificationPrimary: "n1", messagePrimary: "m1", archivedId: "a1", messageId: "mid-1", chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 10), targetMemberId: currentMemberId, groupchatJid: groupchatJid),
                ChatUnreadMentionItem(notificationPrimary: "n2", messagePrimary: "m2", archivedId: "a2", messageId: "mid-2", chatPrimary: "chat-1", authorId: "other", date: Date(timeIntervalSince1970: 20), targetMemberId: currentMemberId, groupchatJid: groupchatJid)
            ],
            observerPrimaryIndexMap: ["m1": 0, "m2": 1],
            visiblePrimaries: ["m2"]
        )

        XCTAssertEqual(state.currentTarget?.notificationPrimary, "n2")
        XCTAssertEqual(state.jumpTarget?.notificationPrimary, "n2")
    }

    func testUnreadMentionNavigatorViewUsesCompactIndicatorWithoutArrowButtons() {
        let view = ChatViewController.UnreadMentionsNavigatorView(frame: .zero)
        view.update(mode: .indicator, unreadCount: 1, accentColor: .systemBlue)

        XCTAssertEqual(view.preferredSize, CGSize(width: 44, height: 44))
        XCTAssertFalse(view.showsDirectionalButtons)
        XCTAssertEqual(view.currentUnreadCountText, "1")
    }

    func testUnreadMentionNavigatorViewCapsUnreadCountBadgeAtNinetyNinePlus() {
        let view = ChatViewController.UnreadMentionsNavigatorView(frame: .zero)
        view.update(mode: .indicator, unreadCount: 120, accentColor: .systemBlue)

        XCTAssertEqual(view.currentUnreadCountText, "99+")
    }

    func testUnreadMentionFloatingControlPolicyKeepsScrollDownButtonWhenNavigatorVisible() {
        XCTAssertTrue(
            ChatUnreadMentionFloatingControlPolicy.shouldShowNavigator(
                conversationType: .group,
                unreadCount: 2,
                isSearchMode: false
            )
        )
        XCTAssertTrue(
            ChatUnreadMentionFloatingControlPolicy.shouldShowScrollDownButton(
                requested: true,
                navigatorVisible: true
            )
        )
        XCTAssertTrue(
            ChatUnreadMentionFloatingControlPolicy.shouldShowScrollDownButton(
                requested: true,
                navigatorVisible: false
            )
        )
    }

    func testChatMentionReadOnVisiblePolicyReturnsMatchingUnreadMentionWhenTargetIsVisible() throws {
        let message = makeMessage(
            primary: "m1",
            archivedId: "a1",
            messageId: "mid-1",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            messageId: "mid-1",
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(message, update: .modified)
            realm.add(notification, update: .modified)
        }

        let primaries = ChatMentionReadOnVisiblePolicy.notificationPrimariesToMarkRead(
            for: ChatOpenMessageRequest(
                chatJid: groupchatJid,
                owner: owner,
                conversationType: .group,
                anchor: ChatMessageAnchorRef(
                    messagePrimary: nil,
                    archivedId: "a1",
                    messageId: "mid-1",
                    authorId: "other-1",
                    bodyFingerprint: nil,
                    sourceDate: Date(timeIntervalSince1970: 10)
                ),
                highlight: false,
                markReadOnVisible: true,
                source: .mentionNotification
            ),
            owner: owner,
            chatJid: groupchatJid,
            conversationType: .group,
            positionedPrimary: "m1",
            visiblePrimaries: ["m1"],
            in: realm
        )

        XCTAssertEqual(primaries, ["n1"])
    }

    func testChatMentionReadOnVisiblePolicySkipsWhenTargetIsNotVisible() throws {
        let message = makeMessage(
            primary: "m1",
            archivedId: "a1",
            messageId: "mid-1",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            messageId: "mid-1",
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(message, update: .modified)
            realm.add(notification, update: .modified)
        }

        let primaries = ChatMentionReadOnVisiblePolicy.notificationPrimariesToMarkRead(
            for: ChatOpenMessageRequest(
                chatJid: groupchatJid,
                owner: owner,
                conversationType: .group,
                anchor: ChatMessageAnchorRef(
                    messagePrimary: nil,
                    archivedId: "a1",
                    messageId: "mid-1",
                    authorId: "other-1",
                    bodyFingerprint: nil,
                    sourceDate: Date(timeIntervalSince1970: 10)
                ),
                highlight: false,
                markReadOnVisible: true,
                source: .mentionNotification
            ),
            owner: owner,
            chatJid: groupchatJid,
            conversationType: .group,
            positionedPrimary: "m1",
            visiblePrimaries: [],
            in: realm
        )

        XCTAssertTrue(primaries.isEmpty)
    }

    func testFloatingControlsLayoutPolicyStacksMentionIndicatorAboveScrollButton() {
        let inputHeight: CGFloat = 83
        let scrollOriginY = ChatViewController.FloatingControlsLayoutPolicy.scrollButtonOriginY(
            viewHeight: 812,
            inputHeight: inputHeight
        )
        let mentionOriginY = ChatViewController.FloatingControlsLayoutPolicy.mentionIndicatorOriginY(
            viewHeight: 812,
            mentionHeight: 44,
            inputHeight: inputHeight,
            showsScrollDownButton: true
        )
        let singleMentionOriginY = ChatViewController.FloatingControlsLayoutPolicy.mentionIndicatorOriginY(
            viewHeight: 812,
            mentionHeight: 44,
            inputHeight: inputHeight,
            showsScrollDownButton: false
        )

        XCTAssertLessThan(mentionOriginY, scrollOriginY)
        XCTAssertEqual(
            singleMentionOriginY,
            ChatViewController.FloatingControlsLayoutPolicy.lowerSlotY(
                viewHeight: 812,
                controlHeight: 44,
                inputHeight: inputHeight
            ),
            accuracy: 0.001
        )
    }

    func testUnreadMentionFloatingControlPolicyHidesNavigatorDuringSearch() {
        XCTAssertFalse(
            ChatUnreadMentionFloatingControlPolicy.shouldShowNavigator(
                conversationType: .group,
                unreadCount: 2,
                isSearchMode: true
            )
        )
    }

    func testUnreadMentionMatcherUsesMessageIdFallbackWhenArchivedIdIsMissing() throws {
        let message = makeMessage(
            primary: "m1",
            archivedId: "a1",
            messageId: "mid-1",
            authorId: "other-1",
            mentionMemberIds: [currentMemberId],
            date: Date(timeIntervalSince1970: 10)
        )
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: nil,
            messageId: "mid-1",
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(message, update: .modified)
            realm.add(notification, update: .modified)
        }

        let messages = realm.objects(MessageStorageItem.self)
            .filter("owner == %@ AND opponent == %@", owner, groupchatJid)

        let item = ChatUnreadMentionMatcher.unreadMentionItem(
            from: notification,
            messagesObserver: messages,
            observerLookupMaps: ChatObserverLookupPolicy.build(from: messages),
            in: realm,
            chatPrimary: "chat-1",
            currentMemberId: currentMemberId,
            groupchatJid: groupchatJid
        )

        XCTAssertEqual(item?.notificationPrimary, "n1")
        XCTAssertEqual(item?.messagePrimary, "m1")
        XCTAssertNil(item?.archivedId)
        XCTAssertEqual(item?.messageId, "mid-1")
    }

    func testRefreshLastChatMentionIdsUsesNewestUnreadMentionArchivedId() throws {
        try insertLastChat()
        let older = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            date: Date(timeIntervalSince1970: 10)
        )
        let newer = makeMentionNotification(
            primary: "n2",
            archivedId: "a2",
            date: Date(timeIntervalSince1970: 20)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(older, update: .modified)
            realm.add(newer, update: .modified)
            MentionNotificationSync.refreshLastChatMentionIds(
                owner: owner,
                groupchatJids: [groupchatJid],
                in: realm
            )
        }

        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: groupchatJid, owner: owner, conversationType: .group)
            )
        )
        XCTAssertEqual(chat.mentionId, "a2")
    }

    func testRefreshLastChatMentionIdsMovesToNextNewestUnreadMentionWhenCurrentBecomesRead() throws {
        try insertLastChat()
        let older = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            date: Date(timeIntervalSince1970: 10)
        )
        let newer = makeMentionNotification(
            primary: "n2",
            archivedId: "a2",
            date: Date(timeIntervalSince1970: 20)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(older, update: .modified)
            realm.add(newer, update: .modified)
            MentionNotificationSync.refreshLastChatMentionIds(
                owner: owner,
                groupchatJids: [groupchatJid],
                in: realm
            )
        }

        try realm.write {
            newer.isRead = true
            _ = MentionNotificationSync.reconcile(notification: newer, in: realm)
            MentionNotificationSync.refreshLastChatMentionIds(
                owner: owner,
                groupchatJids: [groupchatJid],
                in: realm
            )
        }

        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: groupchatJid, owner: owner, conversationType: .group)
            )
        )
        XCTAssertEqual(chat.mentionId, "a1")
    }

    func testRefreshLastChatMentionIdsClearsMentionIdWhenUnreadMentionsAreGone() throws {
        try insertLastChat()
        let notification = makeMentionNotification(
            primary: "n1",
            archivedId: "a1",
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(notification, update: .modified)
            MentionNotificationSync.refreshLastChatMentionIds(
                owner: owner,
                groupchatJids: [groupchatJid],
                in: realm
            )
        }

        try realm.write {
            notification.isRead = true
            _ = MentionNotificationSync.reconcile(notification: notification, in: realm)
            MentionNotificationSync.refreshLastChatMentionIds(
                owner: owner,
                groupchatJids: [groupchatJid],
                in: realm
            )
        }

        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: groupchatJid, owner: owner, conversationType: .group)
            )
        )
        XCTAssertNil(chat.mentionId)
    }

    func testRefreshLastChatMentionIdsSkipsInvalidatedMissingAndDirectConversationMentions() throws {
        try insertLastChat()
        let direct = makeMentionNotification(
            primary: "n-direct",
            archivedId: "a-direct",
            conversationType: .regular,
            date: Date(timeIntervalSince1970: 40)
        )
        let invalidated = makeMentionNotification(
            primary: "n-invalidated",
            archivedId: "a-invalidated",
            linkStatus: .invalidated,
            date: Date(timeIntervalSince1970: 30)
        )
        let missing = makeMentionNotification(
            primary: "n-missing",
            archivedId: "a-missing",
            linkStatus: .missing,
            date: Date(timeIntervalSince1970: 20)
        )
        let valid = makeMentionNotification(
            primary: "n-valid",
            archivedId: "a-valid",
            linkStatus: .resolved,
            date: Date(timeIntervalSince1970: 10)
        )
        let realm = try WRealm.safe()

        try realm.write {
            realm.add(direct, update: .modified)
            realm.add(invalidated, update: .modified)
            realm.add(missing, update: .modified)
            realm.add(valid, update: .modified)
            MentionNotificationSync.refreshLastChatMentionIds(
                owner: owner,
                groupchatJids: [groupchatJid],
                in: realm
            )
        }

        let chat = try XCTUnwrap(
            realm.object(
                ofType: LastChatsStorageItem.self,
                forPrimaryKey: LastChatsStorageItem.genPrimary(jid: groupchatJid, owner: owner, conversationType: .group)
            )
        )
        XCTAssertEqual(chat.mentionId, "a-valid")
    }
}

final class PasscodeLockPolicyTests: XCTestCase {
    func testConfigDisabledBlocksPasscodeLock() {
        let access = PasscodeLockPolicy.access(
            requiredByConfig: false,
            subscriptionsEnabled: false,
            hasActiveSubscription: true
        )

        XCTAssertEqual(access, .disabledByConfig)
    }

    func testConfigEnabledWithoutSubscriptionsAllowsPasscodeLock() {
        let access = PasscodeLockPolicy.access(
            requiredByConfig: true,
            subscriptionsEnabled: false,
            hasActiveSubscription: false
        )

        XCTAssertEqual(access, .available)
    }

    func testSubscriptionsEnabledWithActivePremiumAllowsPasscodeLock() {
        let access = PasscodeLockPolicy.access(
            requiredByConfig: true,
            subscriptionsEnabled: true,
            hasActiveSubscription: true
        )

        XCTAssertEqual(access, .available)
    }

    func testSubscriptionsEnabledWithoutPremiumRequiresPremium() {
        let access = PasscodeLockPolicy.access(
            requiredByConfig: true,
            subscriptionsEnabled: true,
            hasActiveSubscription: false
        )

        XCTAssertEqual(access, .premiumRequired)
    }
}

final class AutoDeleteMessagesPolicyTests: XCTestCase {
    func testDisablingAutoDeleteDoesNotRequirePremium() {
        let access = AutoDeleteMessagesPolicy.access(
            timerSeconds: 0,
            subscriptionsEnabled: true,
            hasActiveSubscription: false
        )

        XCTAssertEqual(access, .available)
    }

    func testSubscriptionsDisabledAllowsTimerConfiguration() {
        let access = AutoDeleteMessagesPolicy.access(
            timerSeconds: 60,
            subscriptionsEnabled: false,
            hasActiveSubscription: false
        )

        XCTAssertEqual(access, .available)
    }

    func testSubscriptionsEnabledWithoutPremiumRequiresPremiumForNonZeroTimer() {
        let access = AutoDeleteMessagesPolicy.access(
            timerSeconds: 60,
            subscriptionsEnabled: true,
            hasActiveSubscription: false
        )

        XCTAssertEqual(access, .premiumRequired)
    }

    func testSubscriptionsEnabledWithPremiumAllowsTimerConfiguration() {
        let access = AutoDeleteMessagesPolicy.access(
            timerSeconds: 60,
            subscriptionsEnabled: true,
            hasActiveSubscription: true
        )

        XCTAssertEqual(access, .available)
    }
}

private final class FakeCloudStorageQuotaAPIClient: CloudStorageQuotaAPIClient {
    var statsResponses: [CloudStorageQuotaAPIResponse] = []
    var slotResponses: [CloudStorageQuotaAPIResponse] = []
    var pendingStats: [(CloudStorageQuotaAPIResponse) -> Void] = []
    private(set) var statsCallCount = 0
    private(set) var slotCallCount = 0

    func getStats(baseURL: URL, token: String, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        statsCallCount += 1
        if statsResponses.isEmpty {
            pendingStats.append(completion)
        } else {
            completion(statsResponses.removeFirst())
        }
    }

    func requestSlot(baseURL: URL, token: String, request: CloudStorageUploadSlotRequest, completion: @escaping (CloudStorageQuotaAPIResponse) -> Void) {
        slotCallCount += 1
        completion(slotResponses.isEmpty ? .failure(statusCode: nil, error: nil) : slotResponses.removeFirst())
    }

    func completeStats(_ response: CloudStorageQuotaAPIResponse) {
        let callbacks = pendingStats
        pendingStats.removeAll()
        callbacks.forEach { $0(response) }
    }
}

final class SettingsCloudStorageQuotaDisplayStateTests: XCTestCase {
    func testCachedQuotaFormatsUsedOfTotal() {
        let state = SettingsCloudStorageQuotaDisplayState.resolve(
            hasCachedQuota: true,
            usedBytes: 1024,
            quotaBytes: 2048,
            isRefreshing: false,
            lastRefreshFailed: false,
            isAvailable: true
        )

        let expected = AccountQuotaStorageItem.beautify(size: 1024)
            + " of ".localizeString(id: "of", arguments: [])
            + AccountQuotaStorageItem.beautify(size: 2048)
        XCTAssertEqual(state.detailText, expected)
    }

    func testRefreshingWithoutCachedQuotaShowsUpdating() {
        let state = SettingsCloudStorageQuotaDisplayState.resolve(
            hasCachedQuota: false,
            usedBytes: 0,
            quotaBytes: 0,
            isRefreshing: true,
            lastRefreshFailed: false,
            isAvailable: true
        )

        XCTAssertEqual(state.detailText, "Updating...")
    }

    func testUnavailableWithoutCachedQuotaShowsUnavailable() {
        let state = SettingsCloudStorageQuotaDisplayState.resolve(
            hasCachedQuota: false,
            usedBytes: 0,
            quotaBytes: 0,
            isRefreshing: false,
            lastRefreshFailed: false,
            isAvailable: false
        )

        XCTAssertEqual(state.detailText, "Unavailable")
    }

    func testFailedRefreshWithoutCachedQuotaShowsUnavailable() {
        let state = SettingsCloudStorageQuotaDisplayState.resolve(
            hasCachedQuota: false,
            usedBytes: 0,
            quotaBytes: 0,
            isRefreshing: false,
            lastRefreshFailed: true,
            isAvailable: true
        )

        XCTAssertEqual(state.detailText, "Unavailable")
    }

    func testUnlimitedQuotaFormatsWithoutNegativeByteString() {
        let state = SettingsCloudStorageQuotaDisplayState.resolve(
            hasCachedQuota: true,
            usedBytes: 1024,
            quotaBytes: -1,
            isRefreshing: false,
            lastRefreshFailed: false,
            isAvailable: true
        )

        let expected = AccountQuotaStorageItem.beautify(size: 1024)
            + " of ".localizeString(id: "of", arguments: [])
            + "Unlimited"
        XCTAssertEqual(state.detailText, expected)
    }

    func testZeroQuotaFormatsWithoutPercentageMath() {
        let state = SettingsCloudStorageQuotaDisplayState.resolve(
            hasCachedQuota: true,
            usedBytes: 0,
            quotaBytes: 0,
            isRefreshing: false,
            lastRefreshFailed: false,
            isAvailable: true
        )

        let expected = AccountQuotaStorageItem.beautify(size: 0)
            + " of ".localizeString(id: "of", arguments: [])
            + AccountQuotaStorageItem.beautify(size: 0)
        XCTAssertEqual(state.detailText, expected)
    }
}

final class CloudStorageUpsellCardStateTests: XCTestCase {
    func testNonPremiumAccountReturnsPremiumUpsell() {
        let state = CloudStorageUpsellCardState.resolve(hasActivePremium: false)

        XCTAssertEqual(state.title, "Increase storage")
        XCTAssertEqual(state.body, "Upgrade to Premium to increase your cloud storage capacity and store more media.")
        XCTAssertEqual(state.action, .openPremium)
        XCTAssertTrue(state.isEnabled)
    }

    func testPremiumAccountReturnsDisabledExternalStorageOffer() {
        let state = CloudStorageUpsellCardState.resolve(hasActivePremium: true)

        XCTAssertEqual(state.title, "Increase storage")
        XCTAssertEqual(state.body, "Buy external storage space: 100 GB for $5.")
        XCTAssertEqual(state.action, .disabled)
        XCTAssertFalse(state.isEnabled)
    }

    func testPremiumExternalStorageOfferDoesNotRouteToPremium() {
        let state = CloudStorageUpsellCardState.resolve(hasActivePremium: true)

        XCTAssertNotEqual(state.action, .openPremium)
    }
}

final class CloudStorageQuotaRefreshTests: XCTestCase {
    private let owner = "quota-alice@xabber.com"
    private var fakeClient: FakeCloudStorageQuotaAPIClient!

    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "CloudStorageQuotaRefreshTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
        fakeClient = FakeCloudStorageQuotaAPIClient()
        XabberUploadManager.quotaAPIClient = fakeClient
        XabberUploadManager.tokenExpiredTestingHandler = nil
        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: "node", value: "https://gallery.example/api/")
        SettingManager.shared.saveItem(for: owner, scope: .xabberUploadManager, key: "userToken", value: "token")
        CloudStorageQuotaRefreshCoordinator.shared.resetTestingHooks()
    }

    override func tearDown() {
        XabberUploadManager.quotaAPIClient = AlamofireCloudStorageQuotaAPIClient()
        XabberUploadManager.tokenExpiredTestingHandler = nil
        SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: "node")
        SettingManager.shared.removeItem(for: owner, scope: .xabberUploadManager, key: "userToken")
        CloudStorageQuotaRefreshCoordinator.shared.resetTestingHooks()
        super.tearDown()
    }

    func testSuccessfulStatsRefreshWritesQuotaStorage() throws {
        fakeClient.statsResponses = [.response(statusCode: 200, value: statsPayload(quota: 3000, totalUsed: 1200, imagesUsed: 400))]
        let manager = XabberUploadManager(withOwner: owner)

        let expectation = expectation(description: "quota refresh")
        manager.refreshQuota(reason: .manual) { result in
            XCTAssertEqual(result, .success)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        let item = try XCTUnwrap(try WRealm.safe().object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: owner))
        XCTAssertEqual(item.quotaBytes, 3000)
        XCTAssertEqual(item.totalBytes, 1200)
        XCTAssertEqual(item.imagesBytes, 400)
    }

    func testMalformedStatsDoesNotOverwriteCachedQuota() throws {
        seedQuota(quota: 3000, total: 1000, images: 250)
        fakeClient.statsResponses = [.response(statusCode: 200, value: ["quota": "bad", "total": ["used": 1]])]
        let manager = XabberUploadManager(withOwner: owner)

        let expectation = expectation(description: "quota refresh")
        manager.refreshQuota(reason: .manual) { result in
            XCTAssertEqual(result, .failure)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        let item = try XCTUnwrap(try WRealm.safe().object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: owner))
        XCTAssertEqual(item.quotaBytes, 3000)
        XCTAssertEqual(item.totalBytes, 1000)
        XCTAssertEqual(item.imagesBytes, 250)
    }

    func testPartialStatsPreservesMissingCategoryValues() throws {
        seedQuota(quota: 3000, total: 1000, images: 250)
        fakeClient.statsResponses = [.response(statusCode: 200, value: [
            "quota": 4000,
            "total": ["used": 1200, "count": 4],
            "files": ["used": 700, "count": 2]
        ])]
        let manager = XabberUploadManager(withOwner: owner)

        let expectation = expectation(description: "quota refresh")
        manager.refreshQuota(reason: .manual) { result in
            XCTAssertEqual(result, .success)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        let item = try XCTUnwrap(try WRealm.safe().object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: owner))
        XCTAssertEqual(item.quotaBytes, 4000)
        XCTAssertEqual(item.totalBytes, 1200)
        XCTAssertEqual(item.imagesBytes, 250)
        XCTAssertEqual(item.filesBytes, 700)
    }

    func testUnauthorizedStatsTriggersTokenRefreshWithoutClearingCache() throws {
        seedQuota(quota: 3000, total: 1000, images: 250)
        fakeClient.statsResponses = [.response(statusCode: 401, value: ["status": 401])]
        var expiredOwners: [String] = []
        XabberUploadManager.tokenExpiredTestingHandler = { expiredOwners.append($0) }
        let manager = XabberUploadManager(withOwner: owner)

        let expectation = expectation(description: "quota refresh")
        manager.refreshQuota(reason: .manual) { result in
            XCTAssertEqual(result, .unauthorized)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(expiredOwners, [owner])
        let item = try XCTUnwrap(try WRealm.safe().object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: owner))
        XCTAssertEqual(item.quotaBytes, 3000)
    }

    func testNetworkFailureKeepsCachedQuota() throws {
        seedQuota(quota: 3000, total: 1000, images: 250)
        fakeClient.statsResponses = [.failure(statusCode: nil, error: NSError(domain: "quota", code: -1))]
        let manager = XabberUploadManager(withOwner: owner)

        let expectation = expectation(description: "quota refresh")
        manager.refreshQuota(reason: .manual) { result in
            XCTAssertEqual(result, .failure)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        let item = try XCTUnwrap(try WRealm.safe().object(ofType: AccountQuotaStorageItem.self, forPrimaryKey: owner))
        XCTAssertEqual(item.quotaBytes, 3000)
        XCTAssertEqual(fakeClient.statsCallCount, 1)
    }

    func testConcurrentQuotaRefreshesCoalesceIntoOneRequest() {
        let manager = XabberUploadManager(withOwner: owner)
        let first = expectation(description: "first")
        let second = expectation(description: "second")

        manager.refreshQuota(reason: .manual) { result in
            XCTAssertEqual(result, .success)
            first.fulfill()
        }
        manager.refreshQuota(reason: .screenOpen) { result in
            XCTAssertEqual(result, .success)
            second.fulfill()
        }

        XCTAssertEqual(fakeClient.statsCallCount, 1)
        fakeClient.completeStats(.response(statusCode: 200, value: statsPayload(quota: 3000, totalUsed: 1200)))
        wait(for: [first, second], timeout: 1)
    }

    func testPremiumEntitlementNotificationTriggersOwnerScopedRefresh() {
        let expectation = expectation(description: "premium refresh")
        var calls: [(String, CloudStorageQuotaRefreshReason, Bool)] = []
        CloudStorageQuotaRefreshCoordinator.shared.refreshOwnerHandler = { owner, reason, force, completion in
            calls.append((owner, reason, force))
            completion?(.success)
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .premiumEntitlementDidChange, object: nil, userInfo: ["jid": owner])
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, owner)
        XCTAssertEqual(calls.first?.1, .premiumEntitlementChanged)
        XCTAssertEqual(calls.first?.2, true)
    }

    func testRefreshAllUsesAllProvidedOwners() {
        var refreshedOwners: [String] = []
        CloudStorageQuotaRefreshCoordinator.shared.ownersProvider = { ["a@xabber.com", "b@xabber.com"] }
        CloudStorageQuotaRefreshCoordinator.shared.refreshOwnerHandler = { owner, reason, force, completion in
            XCTAssertEqual(reason, .appLaunch)
            XCTAssertFalse(force)
            refreshedOwners.append(owner)
            completion?(.success)
        }

        CloudStorageQuotaRefreshCoordinator.shared.refreshAll(reason: .appLaunch)

        XCTAssertEqual(refreshedOwners, ["a@xabber.com", "b@xabber.com"])
    }

    func testQuotaDisplayStateCoversImportantStates() {
        XCTAssertEqual(CloudStorageQuotaDisplayState.resolve(hasQuotaItem: false, quotaBytes: 0, usedBytes: 0, isRefreshing: true, lastRefreshFailed: false, isAvailable: true), .loading)
        XCTAssertEqual(CloudStorageQuotaDisplayState.resolve(hasQuotaItem: false, quotaBytes: 0, usedBytes: 0, isRefreshing: false, lastRefreshFailed: true, isAvailable: true), .error)
        XCTAssertEqual(CloudStorageQuotaDisplayState.resolve(hasQuotaItem: false, quotaBytes: 0, usedBytes: 0, isRefreshing: false, lastRefreshFailed: false, isAvailable: false), .unavailable)
        XCTAssertEqual(CloudStorageQuotaDisplayState.resolve(hasQuotaItem: true, quotaBytes: -1, usedBytes: 10, isRefreshing: false, lastRefreshFailed: false, isAvailable: true), .unlimited)
        XCTAssertEqual(CloudStorageQuotaDisplayState.resolve(hasQuotaItem: true, quotaBytes: 100, usedBytes: 0, isRefreshing: false, lastRefreshFailed: false, isAvailable: true), .empty)
        XCTAssertEqual(CloudStorageQuotaDisplayState.resolve(hasQuotaItem: true, quotaBytes: 100, usedBytes: 100, isRefreshing: false, lastRefreshFailed: false, isAvailable: true), .content)
    }

    func testSlotPreflightQuotaExceededStopsUploadAndRefreshesQuota() {
        fakeClient.slotResponses = [.response(statusCode: 403, value: ["status": 403])]
        fakeClient.statsResponses = [.response(statusCode: 200, value: statsPayload(quota: 100, totalUsed: 100))]
        let manager = XabberUploadManager(withOwner: owner)
        let expectation = expectation(description: "slot preflight")
        var errorCode: Int?
        var shouldContinue: Bool?

        manager.preflightUploadSlot(data: Data("file".utf8), filename: "file.txt", errorCallback: {
            errorCode = $0
        }, completion: {
            shouldContinue = $0
            expectation.fulfill()
        })
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(errorCode, 403)
        XCTAssertEqual(shouldContinue, false)
        XCTAssertEqual(fakeClient.slotCallCount, 1)
        XCTAssertEqual(fakeClient.statsCallCount, 1)
    }

    private func seedQuota(quota: Int, total: Int, images: Int) {
        let realm = try! WRealm.safe()
        let item = AccountQuotaStorageItem()
        item.primary = owner
        item.jid = owner
        item.quotaBytes = quota
        item.totalBytes = total
        item.imagesBytes = images
        try! realm.write {
            realm.add(item, update: .modified)
        }
    }

    private func statsPayload(quota: Int, totalUsed: Int, imagesUsed: Int = 0) -> [String: Any] {
        return [
            "quota": quota,
            "total": ["used": totalUsed, "count": 3],
            "images": ["used": imagesUsed, "count": imagesUsed == 0 ? 0 : 1],
            "videos": ["used": 0, "count": 0],
            "files": ["used": 0, "count": 0],
            "audio": ["used": 0, "count": 0],
            "voices": ["used": 0, "count": 0],
            "avatars": ["used": 0, "count": 0]
        ]
    }
}

final class SubscriptionEntitlementCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Realm.Configuration.defaultConfiguration = Realm.Configuration(inMemoryIdentifier: "SubscriptionEntitlementCacheTests-\(name)")
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    func testStoreKitProductIdentifierComposesBackendProductAndPriceIds() {
        let productId = SubscribtionsManager.storeKitProductIdentifier(
            productId: "com_xabber_premium_account",
            priceId: "monthly"
        )

        XCTAssertEqual(productId, "com_xabber_premium_account.monthly")
    }

    func testStoreKitProductIdentifierKeepsAlreadyQualifiedPriceIds() {
        let productId = SubscribtionsManager.storeKitProductIdentifier(
            productId: "com_xabber_premium_account",
            priceId: "com_xabber_premium_account.yearly"
        )

        XCTAssertEqual(productId, "com_xabber_premium_account.yearly")
    }

    func testAPIProductSelectionPrefersProductionPremiumProductOverTestProducts() {
        let product = SubscribtionsManager.apiProduct(from: iosProductsResponse())

        XCTAssertEqual(product?.productId, "com_xabber_premium_account")
        XCTAssertEqual(product?.prices.map { $0.priceId }, ["monthly", "yearly"])
    }

    func testAPIProductSelectionParsesNSDictionaryResponse() {
        let product = SubscribtionsManager.apiProduct(from: iosProductsNSDictionaryResponse())

        XCTAssertEqual(product?.productId, "com_xabber_premium_account")
        XCTAssertEqual(product?.prices.map { $0.price }, ["5", "50"])
    }

    func testPremiumAdvantagesPreferAPIIncludesOverFallbackFeatures() throws {
        let product = try XCTUnwrap(SubscribtionsManager.apiProduct(from: iosProductsResponse()))
        let items = PremiumSubscribtionViewController.advantageItems(
            from: product,
            hasXabberAccount: true,
            jid: "alice@xabber.com"
        )

        XCTAssertEqual(items.map(\.title), ["3 GB File Storage", "Unlimited Message Storage"])
        XCTAssertNil(items.first?.desc)

        guard case .symbol("xabber.checkmark")? = items.first?.kind else {
            return XCTFail("Expected API advantages to use xabber.checkmark")
        }
        XCTAssertEqual(items.first?.color, MDCPalette.green.tint500)
    }

    func testStoreKitProductIdentifiersUseProductionProductAndPriceIds() throws {
        let product = try XCTUnwrap(SubscribtionsManager.apiProduct(from: iosProductsResponse()))
        let identifiers = SubscribtionsManager.storeKitProductIdentifiers(
            for: product,
            fallbackIds: ["com_xabber_premium_account.monthly"]
        )

        XCTAssertEqual(
            identifiers,
            ["com_xabber_premium_account.monthly", "com_xabber_premium_account.yearly"]
        )
    }

    func testFallbackProductIdsCreatePeriodRowsWhenAPIIsUnavailable() throws {
        let product = try XCTUnwrap(
            SubscribtionsManager.apiProductFromFallbackProductIds([
                "com_xabber_premium_account.monthly",
                "com_xabber_premium_account.yearly"
            ])
        )

        XCTAssertEqual(product.productId, "com_xabber_premium_account")
        XCTAssertEqual(product.prices.map { $0.name }, ["Monthly", "Yearly"])
        XCTAssertEqual(product.prices.map { $0.priceId }, ["monthly", "yearly"])
        XCTAssertEqual(
            SubscribtionsManager.storeKitProductIdentifiers(for: product, fallbackIds: []),
            ["com_xabber_premium_account.monthly", "com_xabber_premium_account.yearly"]
        )
    }

    func testSectionsStateUsesLoadedFallbackProductWithWarning() throws {
        let fallbackProduct = try XCTUnwrap(
            SubscribtionsManager.apiProductFromFallbackProductIds([
                "com_xabber_premium_account.monthly",
                "com_xabber_premium_account.yearly"
            ])
        )

        let state = PremiumSubscribtionViewController.sectionsState(
            from: SubscriptionCatalogFetchResult(
                product: fallbackProduct,
                source: .fallback,
                warningMessage: "Fallback",
                errorMessage: nil
            )
        )

        XCTAssertEqual(state, .loaded(product: fallbackProduct, source: .fallback, warning: "Fallback"))
    }

    func testSectionsStateUsesErrorWhenFallbackIsUnavailable() {
        let state = PremiumSubscribtionViewController.sectionsState(
            from: SubscriptionCatalogFetchResult(
                product: nil,
                source: .empty,
                warningMessage: nil,
                errorMessage: "We couldn't load subscriptions. Please try again."
            )
        )

        XCTAssertEqual(state, .error(message: "We couldn't load subscriptions. Please try again."))
    }

    func testEmptyCatalogResponseIsDetected() {
        XCTAssertTrue(SubscribtionsManager.hasEmptyCatalogResponse(["results": []]))
        XCTAssertFalse(SubscribtionsManager.hasEmptyCatalogResponse(iosProductsResponse()))
    }

    func testAPIProductSelectionKeepsBackendPricesWhenStoreKitProductsAreUnavailable() throws {
        let product = try XCTUnwrap(SubscribtionsManager.apiProduct(from: iosProductsResponse()))

        XCTAssertEqual(product.prices.count, 2)
        XCTAssertEqual(product.prices[0].name, "Monthly")
        XCTAssertEqual(product.prices[0].price, "5")
        XCTAssertEqual(product.prices[1].name, "Yearly")
        XCTAssertEqual(product.prices[1].price, "50")
    }

    func testSortedPeriodItemsUseDescendingFallbackPriceOrder() {
        let sortedItems = PremiumSubscribtionViewController.sortedPeriodItems([
            (name: "Monthly", period: "monthly", priceId: "monthly", fallbackPrice: "5", storeProduct: nil),
            (name: "Yearly", period: "yearly", priceId: "yearly", fallbackPrice: "50", storeProduct: nil)
        ])

        XCTAssertEqual(sortedItems.map(\.name), ["Yearly", "Monthly"])
    }

    func testResolvedSelectedPriceIdDefaultsToMostExpensiveSortedPlan() {
        let sortedItems = PremiumSubscribtionViewController.sortedPeriodItems([
            (name: "Monthly", period: "monthly", priceId: "com_xabber_premium_account.monthly", fallbackPrice: "5", storeProduct: nil),
            (name: "Yearly", period: "yearly", priceId: "com_xabber_premium_account.yearly", fallbackPrice: "50", storeProduct: nil)
        ])

        let selectedPriceId = PremiumSubscribtionViewController.resolvedSelectedPriceId(
            previousSelectedPriceId: nil,
            items: sortedItems
        )

        XCTAssertEqual(selectedPriceId, "com_xabber_premium_account.yearly")
    }

    func testResolvedSelectedPriceIdPreservesExistingSelectionDuringReload() {
        let sortedItems = PremiumSubscribtionViewController.sortedPeriodItems([
            (name: "Monthly", period: "monthly", priceId: "com_xabber_premium_account.monthly", fallbackPrice: "5", storeProduct: nil),
            (name: "Yearly", period: "yearly", priceId: "com_xabber_premium_account.yearly", fallbackPrice: "50", storeProduct: nil)
        ])

        let selectedPriceId = PremiumSubscribtionViewController.resolvedSelectedPriceId(
            previousSelectedPriceId: "com_xabber_premium_account.monthly",
            items: sortedItems
        )

        XCTAssertEqual(selectedPriceId, "com_xabber_premium_account.monthly")
    }

    func testResolvedSelectedPriceIdFallsBackToFirstPlanWhenPreviousSelectionDisappears() {
        let sortedItems = PremiumSubscribtionViewController.sortedPeriodItems([
            (name: "Yearly", period: "yearly", priceId: "com_xabber_premium_account.yearly", fallbackPrice: "50", storeProduct: nil)
        ])

        let selectedPriceId = PremiumSubscribtionViewController.resolvedSelectedPriceId(
            previousSelectedPriceId: "com_xabber_premium_account.monthly",
            items: sortedItems
        )

        XCTAssertEqual(selectedPriceId, "com_xabber_premium_account.yearly")
    }

    func testSortedPeriodItemsFallsBackToBillingMonthsWhenPricesAreMissing() {
        let sortedItems = PremiumSubscribtionViewController.sortedPeriodItems([
            (name: "Monthly", period: "monthly", priceId: "com_xabber_premium_account.monthly", fallbackPrice: "", storeProduct: nil),
            (name: "Yearly", period: "yearly", priceId: "com_xabber_premium_account.yearly", fallbackPrice: "", storeProduct: nil)
        ])

        XCTAssertEqual(sortedItems.map(\.priceId), [
            "com_xabber_premium_account.yearly",
            "com_xabber_premium_account.monthly"
        ])
    }

    func testBillingMonthsUsesFallbackPeriodWhenStoreKitIsUnavailable() {
        XCTAssertEqual(PremiumSubscribtionViewController.billingMonths(for: nil, period: "yearly"), 12)
        XCTAssertEqual(PremiumSubscribtionViewController.billingMonths(for: nil, period: "monthly"), 1)
    }

    func testAnnualSavingsTextIncludesAmountAndPercentage() {
        let savingsText = PremiumSubscribtionViewController.savingsText(
            totalPrice: 50,
            totalMonths: 12,
            monthlyUnitPrice: 5,
            storeProduct: nil
        )

        XCTAssertEqual(savingsText, "Save 10 (16%)")
    }

    func testAnnualSavingsTextReturnsNilWithoutDiscount() {
        XCTAssertNil(
            PremiumSubscribtionViewController.savingsText(
                totalPrice: 60,
                totalMonths: 12,
                monthlyUnitPrice: 5,
                storeProduct: nil
            )
        )
    }

    func testAboutTextUsesJustifiedParagraphStyle() throws {
        let attributedText = PremiumSubscribtionViewController.aboutTextAttributedString("About")
        let paragraphStyle = try XCTUnwrap(
            attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )

        XCTAssertEqual(paragraphStyle.alignment, .justified)
        XCTAssertGreaterThan(paragraphStyle.lineSpacing, 0)
    }

    func testLoadingCTAStateIsVisibleAndDisabled() {
        let ctaState = PremiumSubscribtionViewController.ctaState(
            remoteState: .loading,
            selectedItem: nil,
            selectedAction: nil,
            isProcessing: false
        )

        XCTAssertEqual(ctaState, PremiumCTAState(title: "Loading Plans…", isEnabled: false))
    }

    func testEmptyCTAStateIsDisabled() {
        let ctaState = PremiumSubscribtionViewController.ctaState(
            remoteState: .empty(warning: nil),
            selectedItem: nil,
            selectedAction: nil,
            isProcessing: false
        )

        XCTAssertEqual(ctaState, PremiumCTAState(title: "No Plans Available", isEnabled: false))
    }

    func testPremiumSkeletonHelperCountsMatchTwoRemoteRows() {
        XCTAssertEqual(PremiumSubscribtionViewController.periodSkeletonRowCount, 2)
        XCTAssertEqual(PremiumSubscribtionViewController.advantageSkeletonRowCount, 2)
    }

    func testSelectionIndicatorUsesSelectedIconAndAccentColor() {
        let imageView = UIImageView()

        PremiumSubscribtionViewController.applySelectionIndicator(
            to: imageView,
            isSelected: true,
            isEnabled: true,
            accentColor: .systemPurple
        )

        XCTAssertEqual(
            PremiumSubscribtionViewController.selectionIndicatorImageName(isSelected: true),
            "checkmark.circle.fill"
        )
        XCTAssertEqual(imageView.tintColor, .systemPurple)
    }

    func testSelectionIndicatorUsesUnselectedIconAndDisabledTint() {
        let imageView = UIImageView()

        PremiumSubscribtionViewController.applySelectionIndicator(
            to: imageView,
            isSelected: false,
            isEnabled: false,
            accentColor: .systemPurple
        )

        XCTAssertEqual(
            PremiumSubscribtionViewController.selectionIndicatorImageName(isSelected: false),
            "circle"
        )
        XCTAssertEqual(imageView.tintColor, .quaternaryLabel)
    }

    func testMalformedProductResponsesReturnNilInsteadOfCrashing() {
        XCTAssertNil(SubscribtionsManager.apiProduct(from: ["results": "bad"]))
        XCTAssertNil(SubscribtionsManager.apiProduct(from: ["items": []]))
        XCTAssertNil(SubscribtionsManager.apiProduct(from: ["results": [["product_id": "com_xabber_premium_account"]]]))
    }

    func testAccountScopedPremiumIgnoresAnotherAccountsActiveSubscription() {
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "bob@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "bob@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: 3600),
            purchaseDate: Date(),
            transactionId: "tx-bob"
        )

        XCTAssertFalse(SubscribtionsManager.shared.hasActiveSubsription(for: "alice@xabber.com"))
        XCTAssertTrue(SubscribtionsManager.shared.hasActiveSubsription(for: "bob@xabber.com"))
    }

    func testAccountScopedPremiumAcceptsMatchingAccountTokenWithoutJid() {
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: 3600),
            purchaseDate: Date(),
            transactionId: "tx-alice"
        )

        XCTAssertTrue(SubscribtionsManager.shared.hasActiveSubsription(for: "alice@xabber.com"))
        XCTAssertEqual(
            SubscribtionsManager.shared.getPurchasedProductIds(for: "alice@xabber.com"),
            ["com_xabber_premium_account.monthly"]
        )
    }

    func testEmptyJidWithoutMatchingAccountTokenDoesNotGrantPremiumToCurrentAccount() {
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "",
            accountUUID: "",
            expires: Date(timeIntervalSinceNow: 3600),
            purchaseDate: Date(),
            transactionId: "tx-empty"
        )

        XCTAssertFalse(SubscribtionsManager.shared.hasActiveSubsription(for: "alice@xabber.com"))
    }

    func testGlobalPremiumIgnoresRestoredTransactionsForUnknownAccounts() {
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "",
            accountUUID: UUID().uuidString,
            expires: Date(timeIntervalSinceNow: 3600),
            purchaseDate: Date(),
            transactionId: "tx-unknown"
        )

        XCTAssertFalse(SubscribtionsManager.shared.hasActiveSubsription())
    }

    func testGlobalPremiumAllowsRowsForLocallyKnownAccounts() throws {
        let realm = try WRealm.safe()
        let account = AccountStorageItem()
        account.jid = "alice@xabber.com"
        try realm.write {
            realm.add(account, update: .modified)
        }

        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: 3600),
            purchaseDate: Date(),
            transactionId: "tx-local"
        )

        XCTAssertTrue(SubscribtionsManager.shared.hasActiveSubsription())
    }

    func testDuplicateTransactionUpdatesExistingSubscriptionRow() throws {
        let firstExpiry = Date(timeIntervalSinceNow: 3600)
        let secondExpiry = Date(timeIntervalSinceNow: 7200)
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: firstExpiry,
            purchaseDate: Date(),
            transactionId: "tx-alice"
        )

        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.yearly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: secondExpiry,
            purchaseDate: Date(),
            transactionId: "tx-alice"
        )

        XCTAssertEqual(SubscribtionsManager.shared.getPurchasedProductIds(for: "alice@xabber.com"), ["com_xabber_premium_account.yearly"])
        let expiresDate = try XCTUnwrap(SubscribtionsManager.shared.getExpiresDate(for: "alice@xabber.com"))
        XCTAssertEqual(expiresDate.timeIntervalSince1970, secondExpiry.timeIntervalSince1970, accuracy: 1)
    }

    func testOlderActiveRowDoesNotShortenNewerRenewalExpiry() throws {
        let olderExpiry = Date(timeIntervalSinceNow: 3600)
        let newerExpiry = Date(timeIntervalSinceNow: 7200)
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: newerExpiry,
            purchaseDate: Date(),
            transactionId: "tx-newer"
        )
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: olderExpiry,
            purchaseDate: Date(),
            transactionId: "tx-older"
        )

        XCTAssertTrue(SubscribtionsManager.shared.hasActiveSubsription(for: "alice@xabber.com"))
        let expiresDate = try XCTUnwrap(SubscribtionsManager.shared.getExpiresDate(for: "alice@xabber.com"))
        XCTAssertEqual(expiresDate.timeIntervalSince1970, newerExpiry.timeIntervalSince1970, accuracy: 1)
    }

    func testRemoveSubscriptionDeletesAccountTokenOnlyRows() {
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: 3600),
            purchaseDate: Date(),
            transactionId: "tx-token-only"
        )

        SubscribtionsManager.shared.remove(for: "alice@xabber.com", commitTransaction: true)

        XCTAssertFalse(SubscribtionsManager.shared.hasActiveSubsription(for: "alice@xabber.com"))
    }

    func testExpiredSubscriptionDoesNotGrantPremiumAndReportsExpiredState() {
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: -3600),
            purchaseDate: Date(timeIntervalSinceNow: -7200),
            transactionId: "tx-expired"
        )

        XCTAssertFalse(SubscribtionsManager.shared.hasActiveSubsription(for: "alice@xabber.com"))
        XCTAssertEqual(SubscribtionsManager.shared.getState(account: "alice@xabber.com"), .expired)
    }

    func testAccountProductsActiveResponseGrantsAccountScopedPremium() throws {
        let expires = Date(timeIntervalSinceNow: 3600)
        let products = accountProductsResponse(status: "ACTIVE", expires: expires.XMPPFormattedDate, priceId: "monthly")

        let activeProducts = try XCTUnwrap(SubscribtionsManager.activePremiumAccountProducts(from: products, now: Date()))
        XCTAssertEqual(activeProducts.map { $0.storeKitProductId }, ["com_xabber_premium_account.monthly"])

        XCTAssertTrue(SubscribtionsManager.shared.reconcileAccountProducts(activeProducts, for: "alice@xabber.com"))
        XCTAssertTrue(SubscribtionsManager.shared.hasActiveSubsription(for: "alice@xabber.com"))
        XCTAssertEqual(SubscribtionsManager.shared.getPurchasedProductIds(for: "alice@xabber.com"), ["com_xabber_premium_account.monthly"])
    }

    func testAccountProductsIntegerActiveStatusIsAccepted() throws {
        let expires = Date(timeIntervalSinceNow: 3600)
        let products = accountProductsResponse(status: 2, expires: expires.XMPPFormattedDate, priceId: "yearly")

        let activeProducts = try XCTUnwrap(SubscribtionsManager.activePremiumAccountProducts(from: products, now: Date()))

        XCTAssertEqual(activeProducts.map { $0.storeKitProductId }, ["com_xabber_premium_account.yearly"])
    }

    func testAccountProductsExpiredResponseDowngradesStaleLocalPremium() throws {
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: 3600),
            purchaseDate: Date(),
            transactionId: "tx-stale"
        )
        let products = accountProductsResponse(status: "SUSPENDED", expires: Date(timeIntervalSinceNow: -60).XMPPFormattedDate, priceId: "monthly")
        let activeProducts = try XCTUnwrap(SubscribtionsManager.activePremiumAccountProducts(from: products, now: Date()))

        XCTAssertTrue(SubscribtionsManager.shared.reconcileAccountProducts(activeProducts, for: "alice@xabber.com"))

        XCTAssertFalse(SubscribtionsManager.shared.hasActiveSubsription(for: "alice@xabber.com"))
    }

    func testMalformedAccountProductsResponseDoesNotDowngradeLocalPremium() {
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: 3600),
            purchaseDate: Date(),
            transactionId: "tx-local"
        )

        XCTAssertNil(SubscribtionsManager.activePremiumAccountProducts(from: ["results": []], now: Date()))
        XCTAssertTrue(SubscribtionsManager.shared.hasActiveSubsription(for: "alice@xabber.com"))
    }

    func testSubscriptionPresentationStateUsesSingleActiveMonthlyPlan() {
        let purchaseDate = Date(timeIntervalSinceNow: -300)
        let expires = Date(timeIntervalSinceNow: 3600)

        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: expires,
            purchaseDate: purchaseDate,
            transactionId: "tx-monthly"
        )

        let state = SubscribtionsManager.shared.subscriptionPresentationState(for: "alice@xabber.com")

        XCTAssertTrue(state.hasActiveEntitlement)
        XCTAssertEqual(state.activeProductId, "com_xabber_premium_account.monthly")
        XCTAssertEqual(try XCTUnwrap(state.activeExpires).timeIntervalSince1970, expires.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(state.scheduledProductId)
    }

    func testSubscriptionPresentationStatePrefersNewerAnnualOverOlderMonthly() {
        let olderPurchaseDate = Date(timeIntervalSinceNow: -600)
        let newerPurchaseDate = Date(timeIntervalSinceNow: -60)

        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: 3600),
            purchaseDate: olderPurchaseDate,
            transactionId: "tx-monthly-old"
        )
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.yearly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: 7200),
            purchaseDate: newerPurchaseDate,
            transactionId: "tx-yearly-new"
        )

        let state = SubscribtionsManager.shared.subscriptionPresentationState(for: "alice@xabber.com")

        XCTAssertEqual(state.activeProductId, "com_xabber_premium_account.yearly")
    }

    func testSubscriptionPresentationStatePrefersNewerMonthlyOverOlderAnnual() {
        let olderPurchaseDate = Date(timeIntervalSinceNow: -600)
        let newerPurchaseDate = Date(timeIntervalSinceNow: -60)

        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.yearly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: 7200),
            purchaseDate: olderPurchaseDate,
            transactionId: "tx-yearly-old"
        )
        SubscribtionsManager.shared.saveSubscriptionInfo(
            productId: "com_xabber_premium_account.monthly",
            jid: "alice@xabber.com",
            accountUUID: SubscribtionsManager.appAccountToken(for: "alice@xabber.com").uuidString,
            expires: Date(timeIntervalSinceNow: 3600),
            purchaseDate: newerPurchaseDate,
            transactionId: "tx-monthly-new"
        )

        let state = SubscribtionsManager.shared.subscriptionPresentationState(for: "alice@xabber.com")

        XCTAssertEqual(state.activeProductId, "com_xabber_premium_account.monthly")
    }

    func testPremiumSubscriptionActionShowsUpgradeForAnnualSelection() {
        let action = PremiumSubscribtionViewController.action(
            selectedName: "Yearly",
            selectedPriceId: "com_xabber_premium_account.yearly",
            selectedHasStoreProduct: true,
            activeProductId: "com_xabber_premium_account.monthly"
        )

        XCTAssertEqual(action, .upgrade(planName: "Yearly"))
    }

    func testPremiumSubscriptionActionShowsDowngradeForMonthlySelection() {
        let action = PremiumSubscribtionViewController.action(
            selectedName: "Monthly",
            selectedPriceId: "com_xabber_premium_account.monthly",
            selectedHasStoreProduct: true,
            activeProductId: "com_xabber_premium_account.yearly"
        )

        XCTAssertEqual(action, .downgrade(planName: "Monthly"))
    }

    func testPremiumSubscriptionActionShowsManageForActivePlanSelection() {
        let action = PremiumSubscribtionViewController.action(
            selectedName: "Monthly",
            selectedPriceId: "com_xabber_premium_account.monthly",
            selectedHasStoreProduct: true,
            activeProductId: "com_xabber_premium_account.monthly"
        )

        XCTAssertEqual(action, .manage)
    }

    func testPremiumSubscriptionActionShowsSubscribeWithoutActivePlan() {
        let action = PremiumSubscribtionViewController.action(
            selectedName: "Yearly",
            selectedPriceId: "com_xabber_premium_account.yearly",
            selectedHasStoreProduct: true,
            activeProductId: nil
        )

        XCTAssertEqual(action, .subscribe)
    }

    func testPremiumPeriodRowStateShowsOnlyOneActiveSubscription() {
        XCTAssertEqual(
            PremiumSubscribtionViewController.rowState(
                forProductId: "com_xabber_premium_account.monthly",
                activeProductId: "com_xabber_premium_account.yearly",
                scheduledProductId: nil,
                hasStoreProduct: true
            ),
            .selectable
        )
        XCTAssertEqual(
            PremiumSubscribtionViewController.rowState(
                forProductId: "com_xabber_premium_account.yearly",
                activeProductId: "com_xabber_premium_account.yearly",
                scheduledProductId: nil,
                hasStoreProduct: true
            ),
            .active
        )
    }

    func testPremiumPeriodRowStateSeparatesScheduledPlanFromActivePlan() {
        XCTAssertEqual(
            PremiumSubscribtionViewController.rowState(
                forProductId: "com_xabber_premium_account.monthly",
                activeProductId: "com_xabber_premium_account.monthly",
                scheduledProductId: "com_xabber_premium_account.yearly",
                hasStoreProduct: true
            ),
            .active
        )
        XCTAssertEqual(
            PremiumSubscribtionViewController.rowState(
                forProductId: "com_xabber_premium_account.yearly",
                activeProductId: "com_xabber_premium_account.monthly",
                scheduledProductId: "com_xabber_premium_account.yearly",
                hasStoreProduct: true
            ),
            .scheduled
        )
    }

    private func iosProductsResponse() -> [String: Any] {
        [
            "results": [
                [
                    "id": 12,
                    "product_id": "early_test_xabber_subs_1_month_prod_id",
                    "display_name": "Test",
                    "group": "ios",
                    "weight": 2,
                    "default": false,
                    "prices": [
                        [
                            "name": "Monthly",
                            "price": 5.0,
                            "price_id": "monthly",
                            "price_description": "",
                            "period": "monthly"
                        ]
                    ],
                    "includes": []
                ],
                [
                    "id": 25,
                    "product_id": "com_xabber_premium_account",
                    "display_name": "Premium",
                    "group": "ios",
                    "weight": 2,
                    "default": false,
                    "prices": [
                        [
                            "name": "Monthly",
                            "price": 5.0,
                            "price_id": "monthly",
                            "price_description": "",
                            "period": "monthly"
                        ],
                        [
                            "name": "Yearly",
                            "price": 50.0,
                            "price_id": "yearly",
                            "price_description": "",
                            "period": "yearly"
                        ]
                    ],
                    "includes": [
                        "3 GB File Storage",
                        "Unlimited Message Storage"
                    ]
                ]
            ]
        ]
    }

    private func iosProductsNSDictionaryResponse() -> NSDictionary {
        iosProductsResponse() as NSDictionary
    }

    private func accountProductsResponse(status: Any, expires: String?, priceId: String) -> [[String: Any]] {
        [
            [
                "id": 1,
                "expires": expires as Any,
                "status": status,
                "quantity": 1,
                "product_data": [
                    "id": 25,
                    "product_id": "com_xabber_premium_account",
                    "display_name": "Premium",
                    "weight": 2,
                    "group": "ios",
                    "default": false
                ],
                "price_data": [
                    "id": 1,
                    "name": priceId.capitalized,
                    "price": "5",
                    "price_id": priceId,
                    "product": 25,
                    "period": priceId
                ],
                "attributes": [:]
            ]
        ]
    }
}
