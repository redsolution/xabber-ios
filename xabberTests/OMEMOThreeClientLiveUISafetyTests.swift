import CryptoKit
import XCTest

final class OMEMOThreeClientLiveUISafetyTests: XCTestCase {
    private let prefix = "XABBER_OMEMO_UI_"

    private func environment(role: String = "iphone") -> [String: String] {
        [
            prefix + "ACCEPTANCE": "1",
            prefix + "ROLE": role,
            prefix + "ACCOUNT": role == "iphone"
                ? "igor.boldin@redsolution.com" : "test.omemo.igor@dxs.xabber.com",
            prefix + "TOKEN": "QA3-E05-native-ui",
            prefix + "BASELINE_SHA256": String(repeating: "a", count: 64)
        ]
    }

    private func evaluate(
        _ environment: [String: String],
        idiom: OMEMOThreeClientLiveUIAuthorization.Idiom = .phone,
        simulator: Bool = false,
        operation: OMEMOThreeClientLiveUIAuthorization.Operation = .report
    ) throws -> OMEMOThreeClientLiveUIAuthorization.Configuration? {
        try OMEMOThreeClientLiveUIAuthorization.authorize(
            environment: environment,
            isSimulator: simulator,
            idiom: idiom,
            operation: operation
        )
    }

    func testMissingOptInSkipsBeforeApplicationCreation() throws {
        XCTAssertNil(try evaluate([:]))
    }

    func testOnlyExactExplicitOptInIsAccepted() throws {
        for value in ["", "0", "true", "yes", " 1"] {
            var env = environment()
            env[prefix + "ACCEPTANCE"] = value
            XCTAssertNil(try evaluate(env))
        }
    }

    func testPhysicalPhoneAccountIsAllowlisted() throws {
        let config = try XCTUnwrap(evaluate(environment()))
        XCTAssertEqual(config.role, .iphone)
        XCTAssertEqual(config.account, "igor.boldin@redsolution.com")
        XCTAssertEqual(config.token, "QA3-E05-native-ui")
    }

    func testPhysicalTabletAccountIsAllowlisted() throws {
        let config = try XCTUnwrap(evaluate(environment(role: "ipad"), idiom: .pad))
        XCTAssertEqual(config.role, .ipad)
        XCTAssertEqual(config.account, "test.omemo.igor@dxs.xabber.com")
    }

    func testGenericDeviceNameDoesNotParticipateInAccountAuthorization() throws {
        var env = environment()
        env[prefix + "REPORTED_DEVICE_NAME"] = "iPhone"
        XCTAssertNotNil(try evaluate(env))
    }

    func testSimulatorIsRejectedEvenWithValidPhysicalRoleInputs() {
        XCTAssertThrowsError(try evaluate(environment(), simulator: true))
    }

    func testMismatchedPhysicalIdiomIsRejected() {
        XCTAssertThrowsError(try evaluate(environment(), idiom: .pad))
        XCTAssertThrowsError(try evaluate(environment(role: "ipad"), idiom: .phone))
        XCTAssertThrowsError(try evaluate(environment(), idiom: .other))
    }

    func testUnknownRoleIsRejected() {
        XCTAssertThrowsError(try evaluate(environment(role: "other")))
    }

    func testCrossRoleOrFullResourceAccountIsRejected() {
        for account in ["test.omemo.igor@dxs.xabber.com", "igor.boldin@redsolution.com/resource", "IGOR.BOLDIN@redsolution.com"] {
            var env = environment()
            env[prefix + "ACCOUNT"] = account
            XCTAssertThrowsError(try evaluate(env))
        }
    }

    func testFreshBoundedQA3TokenIsRequired() {
        for token in ["", "QA3-", "old-E04", "QA3-E05\n", "QA3-" + String(repeating: "x", count: 80)] {
            var env = environment()
            env[prefix + "TOKEN"] = token
            XCTAssertThrowsError(try evaluate(env))
        }
    }

    func testPrivateBaselineDigestIsRequiredButIsNotAnAccountAssertion() {
        for digest in ["", "abc", String(repeating: "g", count: 64), String(repeating: "A", count: 64)] {
            var env = environment()
            env[prefix + "BASELINE_SHA256"] = digest
            XCTAssertThrowsError(try evaluate(env))
        }
    }

    func testFixtureResetAndIsolatedStorageInputsAreRejected() {
        for key in ["XABBER_ISOLATED_STORAGE", "XABBER_CHAT_FIXTURE", "XABBER_RESET_ON_LAUNCH", "TEST_RUNNER_XABBER_ISOLATED_STORAGE", "XABBER_SEED_ACCOUNT", "TEST_RUNNER_XABBER_DISABLE_ACCOUNT_AUTOCONNECT", "XABBER_CHAT_PERFORMANCE_UI_TEST"] {
            var env = environment()
            env[key] = "1"
            XCTAssertThrowsError(try evaluate(env), key)
        }
    }

    func testDisabledFixtureInputDoesNotBlockReadOnlyReport() throws {
        var env = environment()
        env["XABBER_ISOLATED_STORAGE"] = "0"
        XCTAssertNotNil(try evaluate(env))
    }

    func testOptionalScenarioDoesNotRunWithBaseOptInOnly() throws {
        XCTAssertNil(try evaluate(environment(), operation: .visibleMessage))
        XCTAssertNil(try evaluate(environment(), operation: .terminalDone))
    }

    func testVisibleMessageRequiresExactManifestUUIDAndFreshTaggedBody() throws {
        var env = environment()
        env[prefix + "ASSERT_MESSAGE"] = "1"
        env[prefix + "MESSAGE_ID"] = "a825179b-420c-4c29-85ad-5d8dafb4851f"
        env[prefix + "MESSAGE_BODY"] = "QA3-E05-native-ui — кириллица 🔐"
        try bindManifest(&env)
        let config = try XCTUnwrap(evaluate(env, operation: .visibleMessage))
        XCTAssertEqual(config.messageBody, env[prefix + "MESSAGE_BODY"])
    }

    func testVisibleMessageRejectsUntaggedBodyOrInvalidUUID() {
        var env = environment()
        env[prefix + "ASSERT_MESSAGE"] = "1"
        env[prefix + "MESSAGE_ID"] = "not-an-id"
        env[prefix + "MESSAGE_BODY"] = "QA3-E05-native-ui"
        XCTAssertThrowsError(try evaluate(env, operation: .visibleMessage))
        env[prefix + "MESSAGE_ID"] = UUID().uuidString
        env[prefix + "MESSAGE_BODY"] = "old personal message"
        XCTAssertThrowsError(try evaluate(env, operation: .visibleMessage))
    }

    func testVisibleMessageAcceptsActualEightCharacterNativeIDWithExactManifestBinding() throws {
        var env = environment()
        env[prefix + "ASSERT_MESSAGE"] = "1"
        env[prefix + "MESSAGE_ID"] = "uT4_rN~v"
        env[prefix + "MESSAGE_BODY"] = "QA3-E05-native-ui — exact native body"
        try bindManifest(&env)
        let config = try XCTUnwrap(evaluate(env, operation: .visibleMessage))
        XCTAssertEqual(config.messageID, "uT4_rN~v")
    }

    func testVisibleMessageAcceptsObservedNativeTildeIdentifier() throws {
        var env = environment()
        env[prefix + "ASSERT_MESSAGE"] = "1"
        env[prefix + "MESSAGE_ID"] = "F~jFuDwQ"
        env[prefix + "MESSAGE_BODY"] = "QA3-E05-native-ui — actual sender ID"
        try bindManifest(&env)
        XCTAssertEqual(try evaluate(env, operation: .visibleMessage)?.messageID, "F~jFuDwQ")
    }

    func testVisibleMessageRejectsHyphenOutsideNativeNanoIDAlphabet() throws {
        var env = environment()
        env[prefix + "ASSERT_MESSAGE"] = "1"
        env[prefix + "MESSAGE_ID"] = "F-jFuDwQ"
        env[prefix + "MESSAGE_BODY"] = "QA3-E05-native-ui — unsupported native ID"
        try bindManifest(&env)
        XCTAssertThrowsError(try evaluate(env, operation: .visibleMessage))
    }

    func testVisibleMessageCannotRunWithoutActualManifestBytesAndHash() throws {
        var env = environment()
        env[prefix + "ASSERT_MESSAGE"] = "1"
        env[prefix + "MESSAGE_ID"] = "a825179b-420c-4c29-85ad-5d8dafb4851f"
        env[prefix + "MESSAGE_BODY"] = "QA3-E05-native-ui — exact body"
        XCTAssertThrowsError(try evaluate(env, operation: .visibleMessage))
    }

    func testVisibleMessageRejectsBodyNotMatchingTheBoundManifestRecord() throws {
        var env = environment()
        env[prefix + "ASSERT_MESSAGE"] = "1"
        env[prefix + "MESSAGE_ID"] = "a825179b-420c-4c29-85ad-5d8dafb4851f"
        env[prefix + "MESSAGE_BODY"] = "QA3-E05-native-ui — exact body"
        try bindManifest(&env)
        env[prefix + "MESSAGE_BODY"] = "QA3-E05-native-ui — changed body"
        XCTAssertThrowsError(try evaluate(env, operation: .visibleMessage))
    }

    func testVisibleMessageRejectsWrongManifestHash() throws {
        var env = environment()
        env[prefix + "ASSERT_MESSAGE"] = "1"
        env[prefix + "MESSAGE_ID"] = "a825179b-420c-4c29-85ad-5d8dafb4851f"
        env[prefix + "MESSAGE_BODY"] = "QA3-E05-native-ui — exact body"
        try bindManifest(&env)
        env[prefix + "MESSAGE_MANIFEST_SHA256"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try evaluate(env, operation: .visibleMessage))
    }

    func testVisibleMessageRejectsDuplicateLogicalIDInManifest() throws {
        var env = environment()
        env[prefix + "ASSERT_MESSAGE"] = "1"
        env[prefix + "MESSAGE_ID"] = "a825179b-420c-4c29-85ad-5d8dafb4851f"
        env[prefix + "MESSAGE_BODY"] = "QA3-E05-native-ui — exact body"
        try bindManifest(&env, duplicate: true)
        XCTAssertThrowsError(try evaluate(env, operation: .visibleMessage))
    }

    private func bindManifest(_ env: inout [String: String], duplicate: Bool = false) throws {
        let record = ["id": env[prefix + "MESSAGE_ID"]!, "body": env[prefix + "MESSAGE_BODY"]!, "sender": "iphone"]
        let data = try JSONSerialization.data(withJSONObject: duplicate ? [record, record] : [record], options: [.sortedKeys])
        env[prefix + "MESSAGE_MANIFEST_BASE64"] = data.base64EncodedString()
        env[prefix + "MESSAGE_MANIFEST_SHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testTerminalDismissalNeedsAnExplicitAlreadySuccessfulSessionWitness() throws {
        var env = environment()
        env[prefix + "DISMISS_SUCCESS"] = "1"
        env[prefix + "VERIFIED_SID"] = "AQIDBAUGBwgJCgsMDQ4PEA=="
        env[prefix + "SUCCESS_LABEL"] = "Verification Successful"
        env[prefix + "DONE_LABEL"] = "Great"
        let config = try XCTUnwrap(evaluate(env, operation: .terminalDone))
        XCTAssertEqual(config.successLabel, "Verification Successful")
        XCTAssertEqual(config.doneLabel, "Great")
    }

    func testTerminalDismissalCannotSelectCancelAcceptOrVerificationButtons() {
        for label in ["Cancel", "Cancel verification", "Verify", "Submit", "Proceed to Verification", ""] {
            var env = environment()
            env[prefix + "DISMISS_SUCCESS"] = "1"
            env[prefix + "VERIFIED_SID"] = "AQIDBAUGBwgJCgsMDQ4PEA=="
            env[prefix + "SUCCESS_LABEL"] = "Verification Successful"
            env[prefix + "DONE_LABEL"] = label
            XCTAssertThrowsError(try evaluate(env, operation: .terminalDone), label)
        }
    }

    func testObservedRussianSuccessHeadingAndNormalGreatButtonAreAllowed() throws {
        var env = environment(role: "ipad")
        env[prefix + "DISMISS_SUCCESS"] = "1"
        env[prefix + "VERIFIED_SID"] = "AQIDBAUGBwgJCgsMDQ4PEA=="
        env[prefix + "SUCCESS_LABEL"] = "Проверка выполнена"
        env[prefix + "DONE_LABEL"] = "Отлично"
        XCTAssertNotNil(try evaluate(env, idiom: .pad, operation: .terminalDone))
    }

    func testTerminalDismissalRejectsMissingOrNoncanonicalSessionWitness() {
        for sid in ["", "not-base64", "AQID\n"] {
            var env = environment()
            env[prefix + "DISMISS_SUCCESS"] = "1"
            env[prefix + "VERIFIED_SID"] = sid
            env[prefix + "SUCCESS_LABEL"] = "Verification Successful"
            env[prefix + "DONE_LABEL"] = "Great"
            XCTAssertThrowsError(try evaluate(env, operation: .terminalDone))
        }
    }
}
