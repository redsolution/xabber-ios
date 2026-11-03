import XCTest
import Foundation
import RealmSwift
import XMPPFramework
import CocoaLumberjack
import CryptoKit
@testable import xabber

final class DevicesAuthenticationPublicationContractTests: XCTestCase {
    private final class Stream: XMPPStream {
        var authenticated = true
        var disconnected = false
        override var isAuthenticated: Bool { authenticated }
        override var isDisconnected: Bool { disconnected }
        override var isConnected: Bool { !disconnected }
    }
    private var previousRealm: Realm.Configuration!
    private var keeper: Realm!
    private var owner = ""
    private let ns = "https://xabber.com/protocol/devices"

    override func setUpWithError() throws {
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment))
        previousRealm = Realm.Configuration.defaultConfiguration
        owner = "devices-contract-\(UUID().uuidString.lowercased())@example.test"
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: owner)
        keeper = try WRealm.safe()
    }
    override func tearDownWithError() throws {
        guard previousRealm != nil else { return }
        CredentialsManager.shared.getItem(for: owner).release(.authFailedRecoverable)
        keeper = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        previousRealm = nil
    }
    private func stream() -> Stream {
        let value = Stream(); value.myJID = XMPPJID(string: owner + "/current"); return value
    }
    private func reply(deviceID: String = "accepted-device", children: String? = nil,
                       extra: String = "", sender: String? = nil, rootNamespace: String = "") throws -> XMPPIQ {
        let children = children ?? "<secret>Zml4dHVyZS1zZWNyZXQ=</secret><validation-key>Zml4dHVyZS12YWxpZGF0aW9u</validation-key><expire>2000000000</expire>"
        return try XMPPIQ(xmlString: "<iq xmlns='\(rootNamespace)' type='result' id='registration' from='\(sender ?? owner)' to='\(owner)/current'><device xmlns='\(ns)' id='\(deviceID)'>\(children)</device>\(extra)</iq>")
    }
    private func registeredManager(_ wire: Stream) -> XMPPDeviceManager {
        let manager = XMPPDeviceManager(withOwner: owner)
        manager.beginAuthentication(on: wire)
        manager.beginDeviceRegistration(on: wire, requestID: "registration")
        return manager
    }
    func testAcceptedPreBindRegistrationRemainsEligibleWhenFrameworkSASLFlagIsAlreadyTrue() throws {
        let wire = stream(), manager = registeredManager(wire)
        XCTAssertTrue(manager.read(withIQ: try reply(), on: wire))
        XCTAssertEqual(manager.registeredDeviceID(on: wire), "accepted-device")
        manager.recordAuthenticatedSession(on: wire, deviceID: manager.registeredDeviceID(on: wire), didResume: false)
        XCTAssertEqual(manager.authenticatedDeviceID(on: wire), "accepted-device")
    }
    func testRegistrationAfterPasswordBindCannotAttachUUIDToCurrentResource() throws {
        let wire = stream(), manager = XMPPDeviceManager(withOwner: owner)
        manager.beginAuthentication(on: wire)
        manager.recordAuthenticatedSession(on: wire, deviceID: nil, didResume: false)
        manager.beginDeviceRegistration(on: wire, requestID: "registration")
        XCTAssertFalse(manager.read(withIQ: try reply(), on: wire))
        XCTAssertNil(manager.registeredDeviceID(on: wire))
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
    }
    func testPostBindSecretUpdateCannotReplaceAcceptedCurrentUUID() throws {
        let wire = stream(), manager = XMPPDeviceManager(withOwner: owner)
        manager.recordAuthenticatedSession(on: wire, deviceID: "current-device", didResume: false)
        manager.beginDeviceRegistration(on: wire, requestID: "registration")
        XCTAssertFalse(manager.read(withIQ: try reply(deviceID: "other-device"), on: wire))
        XCTAssertNil(manager.registeredDeviceID(on: wire))
        XCTAssertEqual(manager.authenticatedDeviceID(on: wire), "current-device")
    }
    func testRegistrationRequiresValidationKeyInExactDevicesNamespace() throws {
        for children in ["<secret>fixture</secret><expire>2000000000</expire>",
                         "<secret>fixture</secret><validation-key xmlns='urn:foreign'>fixture</validation-key><expire>2000000000</expire>",
                         "<secret>fixture</secret><validation-key> </validation-key><expire>2000000000</expire>"] {
            let wire = stream(), manager = registeredManager(wire)
            XCTAssertFalse(manager.read(withIQ: try reply(children: children), on: wire))
            XCTAssertNil(manager.registeredDeviceID(on: wire))
        }
    }
    func testRegistrationRejectsDuplicatedSecretAndValidationKey() throws {
        for children in ["<secret>one</secret><secret>two</secret><validation-key>fixture</validation-key><expire>2000000000</expire>",
                         "<secret>fixture</secret><validation-key>one</validation-key><validation-key>two</validation-key><expire>2000000000</expire>"] {
            let wire = stream(), manager = registeredManager(wire)
            XCTAssertFalse(manager.read(withIQ: try reply(children: children), on: wire))
            XCTAssertNil(manager.registeredDeviceID(on: wire))
        }
    }
    func testRegistrationRejectsForeignOrNestedSecretPayload() throws {
        for children in ["<secret xmlns='urn:foreign'>fixture</secret><validation-key>fixture</validation-key><expire>2000000000</expire>",
                         "<secret><value>fixture</value></secret><validation-key>fixture</validation-key><expire>2000000000</expire>"] {
            let wire = stream(), manager = registeredManager(wire)
            XCTAssertFalse(manager.read(withIQ: try reply(children: children), on: wire))
        }
    }
    func testRegistrationRejectsAdditionalPayloadAndForeignIQNamespace() throws {
        let wire = stream(), manager = registeredManager(wire)
        XCTAssertFalse(manager.read(withIQ: try reply(extra: "<device xmlns='\(ns)' id='duplicate-device'/>") , on: wire))
        XCTAssertFalse(manager.read(withIQ: try reply(rootNamespace: "urn:foreign"), on: wire))
        XCTAssertNil(manager.registeredDeviceID(on: wire))
    }
    func testRegistrationRequiresOwnBareSenderRatherThanDomainOrOtherResource() throws {
        for sender in ["example.test", owner + "/other-resource"] {
            let wire = stream(), manager = registeredManager(wire)
            XCTAssertFalse(manager.read(withIQ: try reply(sender: sender), on: wire))
            XCTAssertNil(manager.registeredDeviceID(on: wire))
        }
    }
    func testRegistrationRejectsMalformedOpaqueUUIDs() throws {
        for id in ["has space", "line&#10;break", String(repeating: "a", count: 513)] {
            let wire = stream(), manager = registeredManager(wire)
            XCTAssertFalse(manager.read(withIQ: try reply(deviceID: id), on: wire))
            XCTAssertNil(manager.registeredDeviceID(on: wire))
        }
    }
    func testAcceptedAuthenticationRejectsMalformedOpaqueUUIDs() {
        for id in ["has space", "line\nbreak", String(repeating: "a", count: 513)] {
            let wire = stream(), manager = XMPPDeviceManager(withOwner: owner)
            manager.recordAuthenticatedSession(on: wire, deviceID: id, didResume: false)
            XCTAssertNil(manager.authenticatedDeviceID(on: wire))
            XCTAssertNil(manager.authenticatedSessionGeneration(on: wire))
        }
    }
    func testStartingReplacementConnectionRevokesOldAcceptedStreamEvenIfItsFlagsStayAuthenticated() {
        let first = stream(), replacement = stream(), manager = XMPPDeviceManager(withOwner: owner)
        manager.recordAuthenticatedSession(on: first, deviceID: "old-device", didResume: false)
        manager.beginAuthentication(on: replacement)
        XCTAssertNil(manager.authenticatedDeviceID(on: first))
        manager.recordAuthenticatedSession(on: first, deviceID: nil, didResume: true)
        XCTAssertNil(manager.authenticatedDeviceID(on: first))
    }
    func testAcceptedReplacementBindCannotLeaveTwoCurrentAuthenticationWitnesses() {
        let first = stream(), replacement = stream(), manager = XMPPDeviceManager(withOwner: owner)
        manager.recordAuthenticatedSession(on: first, deviceID: "old-device", didResume: false)
        manager.recordAuthenticatedSession(on: replacement, deviceID: "new-device", didResume: false)
        XCTAssertNil(manager.authenticatedDeviceID(on: first))
        XCTAssertEqual(manager.authenticatedDeviceID(on: replacement), "new-device")
    }
    func testRegistrationWithoutReceivingStreamCannotEstablishCurrentProof() throws {
        let wire = stream(), manager = registeredManager(wire)
        XCTAssertFalse(manager.read(withIQ: try reply()))
        XCTAssertNil(manager.registeredDeviceID(on: wire))
    }
    func testDelayedRegistrationProxyFromReplacedStreamCannotSeedCurrentAttempt() throws {
        let first = stream(), replacement = stream()
        let account = Account(jid: owner, queue: DispatchQueue(label: owner))
        account.xmppStream = first
        account.devices.beginAuthentication(on: first)
        account.installDevicesRegistrationDelegate(on: first)
        let previous = try XCTUnwrap(account.devicesRegistrationDelegate)
        account.xmppStream = replacement
        account.devices.beginAuthentication(on: replacement)
        account.installDevicesRegistrationDelegate(on: replacement)
        previous.xmppStreamRequestDeviceRegistration("registration")
        previous.xmppStreamResponseDeviceRegistration(try reply())
        XCTAssertNil(account.devices.registeredDeviceID(on: replacement))
        XCTAssertNil(account.devices.registeredDeviceID(on: first))
        account.devices.clearSession()
    }
    func testDelayedRegistrationProxyFromPreviousAuthAttemptOnSameObjectIsRejected() throws {
        let wire = stream(), account = Account(jid: owner, queue: DispatchQueue(label: owner))
        account.xmppStream = wire
        account.devices.beginAuthentication(on: wire)
        account.installDevicesRegistrationDelegate(on: wire)
        let previous = try XCTUnwrap(account.devicesRegistrationDelegate)
        account.devices.beginAuthentication(on: wire)
        account.installDevicesRegistrationDelegate(on: wire)
        previous.xmppStreamRequestDeviceRegistration("registration")
        previous.xmppStreamResponseDeviceRegistration(try reply())
        XCTAssertNil(account.devices.registeredDeviceID(on: wire))
        let current = try XCTUnwrap(account.devicesRegistrationDelegate)
        current.xmppStreamRequestDeviceRegistration("registration")
        current.xmppStreamResponseDeviceRegistration(try reply())
        XCTAssertEqual(account.devices.registeredDeviceID(on: wire), "accepted-device")
        account.devices.clearSession()
    }
    private final class DeterministicOCRA: DevicesOCRA {
        override func generateClientChallenge() -> String { "a1B2c3D4e5" }
    }
    func testRealOCRARejectsSuccessWithoutMutualServerChallenge() throws {
        let auth = DeterministicOCRA(stream: stream(), secret: Data(repeating: 0x42, count: 32).base64EncodedString(),
            validationKey: "fixture-validation", counter: 1, deviceId: "opaque-device")
        XCTAssertEqual(auth.handleAuth(try DDXMLElement(xmlString: "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/> ")).rawValue, 0)
    }
    func testRealOCRARequiresMatchingServerHMACBeforeAcceptedSuccess() throws {
        let wire = stream()
        let secret = Data(repeating: 0x42, count: 32)
        let auth = DeterministicOCRA(stream: wire, secret: secret.base64EncodedString(),
            validationKey: "fixture-validation", counter: 1, deviceId: "opaque-device")
        try auth.start()
        let suite = "OCRA-1:HOTP-SHA256-8:QA10"
        var input = Data(suite.utf8); input.append(0)
        var question = Data("a1B2c3D4e5".utf8); question.append(Data(repeating: 0, count: 128-question.count))
        input.append(question)
        let hash = Array(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: secret)))
        let offset = Int(hash[hash.count-1] & 0x0f)
        let number = ((UInt32(hash[offset]) << 24) | (UInt32(hash[offset+1]) << 16)
            | (UInt32(hash[offset+2]) << 8) | UInt32(hash[offset+3])) & 0x7fffffff
        let proof = Data(String(format: "%08u", number % 100_000_000).utf8).base64EncodedString()
        let payload = Data((proof + "\0OCRA-1:HOTP-SHA256-8:C-QA10\0server-question").utf8).base64EncodedString()
        let challenge = try DDXMLElement(xmlString: "<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(payload)</challenge>")
        XCTAssertEqual(auth.handleAuth(challenge).rawValue, 2)
        XCTAssertEqual(auth.handleAuth(try DDXMLElement(xmlString: "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")).rawValue, 1)
    }
    func testCachedUUIDAndLegacyHOTPDoNotBecomeStrongDevicesProof() {
        let wire = stream(), manager = XMPPDeviceManager(withOwner: owner)
        manager.deviceId = "cached-device"
        manager.recordAuthenticatedSession(on: wire, deviceID: nil, didResume: false, legacyHOTP: true)
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
    }
}

final class DevicesPrivatePayloadLoggingContractTests: XCTestCase {
    private func log(_ xml: String) -> String {
        ConnectionDiagnosticsLogger.line(event: "stanza_receive_iq", stream: .primary,
            jid: "owner@example.test", rawXML: xml)
    }
    func testRegistrationReplyOmitsEntireRawFrameIncludingCredentialChildren() {
        let frame = "<iq type='result' id='registration-private'><device xmlns='https://xabber.com/protocol/devices' id='device'><secret>registration-secret-sentinel</secret><validation-key>validation-sentinel</validation-key><expire>2000000000</expire><private-extra>extra-private-sentinel</private-extra></device></iq>"
        let line = log(frame)
        for value in [frame, "registration-secret-sentinel", "validation-sentinel", "extra-private-sentinel"] {
            XCTAssertFalse(line.contains(value))
        }
        XCTAssertTrue(line.contains("stanza_receive_iq"))
    }
    func testSASLAuthenticationAndChallengePayloadsAreNotLogged() {
        for element in ["auth", "challenge", "response"] {
            let line = log("<\(element) xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>base64-authentication-sentinel</\(element)>")
            XCTAssertFalse(line.contains("base64-authentication-sentinel"))
        }
    }
    func testDeviceSecretRegistrationRequestIsNotLogged() {
        let line = log("<iq type='set'><register xmlns='https://xabber.com/protocol/devices'><device><secret>existing-device-secret-sentinel</secret></device></register></iq>")
        XCTAssertFalse(line.contains("existing-device-secret-sentinel"))
    }
    func testPrivateKeysAndVerificationCodesAreNotLogged() {
        for payload in ["<private-key>private-key-sentinel</private-key>", "<verification-code>verification-code-sentinel</verification-code>"] {
            let line = log("<message>\(payload)</message>")
            XCTAssertFalse(line.contains("private-key-sentinel"))
            XCTAssertFalse(line.contains("verification-code-sentinel"))
        }
    }
    func testFormatterProtectsFrameworkRawAndEscapedMultilineFrames() throws {
        let formatter = XMPPPrivatePayloadLogFormatter()
        for payload in ["RECV: <iq type='result'>\n<device xmlns='https://xabber.com/protocol/devices'><secret>formatter-private-sentinel</secret></device></iq>",
                        "RECV: &lt;challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'&gt;formatter-private-sentinel&lt;/challenge&gt;",
                        "RECV: <secret>formatter-private-sentinel", "RECV: <auth>formatter-private-sentinel</auth>"] {
            let message = DDLogMessage(message: payload, level: .all, flag: .info, context: 5222,
                file: "XMPPStream.m", function: nil, line: 1, tag: nil, options: [], timestamp: Date())
            let output = try XCTUnwrap(formatter.format(message: message))
            XCTAssertFalse(output.contains("formatter-private-sentinel"))
        }
    }
    func testFormatterOmitsCorrelatedRegistrationErrorAndDuplicateReplyWithoutCredentialTags() throws {
        let formatter = XMPPPrivatePayloadLogFormatter()
        func format(_ text: String) -> String? {
            formatter.format(message: DDLogMessage(message: text, level: .all, flag: .info,
                context: 5222, file: "XMPPStream.m", function: nil, line: 1, tag: nil, options: [], timestamp: Date()))
        }
        _ = format("SEND: <iq id='private-registration-error' type='set'><register xmlns='https://xabber.com/protocol/devices'><device/></register></iq>")
        let reply = "RECV: <iq id='private-registration-error' type='error'><error><text>registration-error-detail-sentinel</text></error></iq>"
        for _ in 0..<2 {
            let output = try XCTUnwrap(format(reply))
            XCTAssertFalse(output.contains("registration-error-detail-sentinel"))
        }
        XCTAssertTrue(try XCTUnwrap(format("RECV: <iq id='other-public-error' type='error'><error><text>public-error-detail</text></error></iq>")).contains("public-error-detail"))
    }
    private final class PrefixFormatter: NSObject, DDLogFormatter {
        func format(message logMessage: DDLogMessage) -> String? { "timestamp " + logMessage.message }
    }
    func testPrivacyFormatterPreservesWrappedTimestampForPublicDiagnostics() throws {
        let formatter = XMPPPrivatePayloadLogFormatter(wrapping: PrefixFormatter())
        let message = DDLogMessage(message: "PUBLIC diagnostic", level: .all, flag: .info, context: 0,
            file: "Account.swift", function: nil, line: 1, tag: nil, options: [], timestamp: Date())
        XCTAssertEqual(formatter.format(message: message), "timestamp PUBLIC diagnostic")
    }
    func testPublicBundleAndOrdinaryIQDiagnosticsRemainAvailable() {
        let xml = "<iq type='set' id='public-bundle'><pubsub xmlns='http://jabber.org/protocol/pubsub'><publish node='urn:xmpp:omemo:2:bundles'><item id='42'><bundle xmlns='urn:xmpp:omemo:2'><ik>public-key-sentinel</ik></bundle></item></publish></pubsub></iq>"
        XCTAssertTrue(log(xml).hasSuffix("\n" + xml))
        XCTAssertTrue(log("<iq type='result' id='public-result'/>").contains("public-result"))
    }
}
