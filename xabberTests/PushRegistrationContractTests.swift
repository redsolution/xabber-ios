import Foundation
import XCTest
import XMPPFramework
@testable import xabber

final class PushRegistrationContractTests: XCTestCase {
    private let owner = "push-contract@example.invalid"
    private let pushService = "push.example.invalid"
    private var nodes: [String] = []

    private final class CapturingStream: XMPPStream {
        private(set) var sentElements: [DDXMLElement] = []
        var onSend: ((DDXMLElement) -> Void)?

        override func send(_ element: DDXMLElement) {
            sentElements.append(element)
            onSend?(element)
        }
    }

    private final class ManualTimeouts {
        final class Task {
            let fire: () -> Void
            var cancelled = false
            init(fire: @escaping () -> Void) { self.fire = fire }
        }
        private(set) var tasks: [Task] = []

        func schedule(_ interval: TimeInterval, _ fire: @escaping () -> Void) -> (() -> Void) {
            let task = Task(fire: fire)
            tasks.append(task)
            return { task.cancelled = true }
        }
    }

    override func tearDown() {
        for node in nodes {
            CredentialsManager.shared.removePushCredentials(for: node)
            PushNotificationsManager.removeDefaultsForPush(target: node, jid: owner)
        }
        nodes.removeAll()
        super.tearDown()
    }

    func testEnableUsesXEPEncryptionElementAndRequestsSummaryMode() throws {
        let (manager, stream, _) = fixture()
        manager.payloadModeProvider = { .summary }

        manager.enable(xmppStream: stream) { _ in }

        let iq = try XCTUnwrap(stream.sentElements.first)
        let enable = try XCTUnwrap(iq.element(forName: "enable", xmlns: manager.getPrimaryNamespace()))
        let encryption = try XCTUnwrap(enable.element(forName: "encryption", xmlns: manager.getPrimaryNamespace()))
        XCTAssertEqual(iq.attributeStringValue(forName: "type"), "set")
        XCTAssertEqual(enable.attributeStringValue(forName: "jid"), pushService)
        XCTAssertEqual(enable.attributeStringValue(forName: "node"), manager.node)
        XCTAssertEqual(enable.attributeStringValue(forName: "mode"), "summary")
        XCTAssertEqual(enable.elements(forName: "encryption").count, 1)
        XCTAssertNil(enable.element(forName: "security"))
        XCTAssertEqual(encryption.attributeStringValue(forName: "algorithm"), "urn:xmpp:ciphers:aes-256-cbc")
        XCTAssertNil(encryption.attributeStringValue(forName: "cipher"))
        XCTAssertEqual(encryption.elements(forName: "key").count, 1)
        XCTAssertNil(encryption.element(forName: "encryption-key"))
        let encodedKey = try XCTUnwrap(encryption.element(forName: "key", xmlns: manager.getPrimaryNamespace())?.stringValue)
        XCTAssertEqual(Data(base64Encoded: encodedKey)?.count, 32)
    }

    func testEmptySuccessfulResultEnablesRegistrationWithoutHTTPGrant() throws {
        let (manager, stream, _) = fixture()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }
        let id = try requestID(stream)

        let consumed = manager.read(withIQ: try response(id: id, body: ""))

        XCTAssertTrue(consumed)
        XCTAssertTrue(manager.enabled)
        XCTAssertFalse(manager.httpPreviewReady)
        XCTAssertEqual(callbacks, [true])
        XCTAssertFalse(manager.queryIds.contains(id))
    }

    func testLegacyInlineFormDoesNotTurnSuccessfulRegistrationIntoFailure() throws {
        let (manager, stream, _) = fixture()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }
        let id = try requestID(stream)

        XCTAssertTrue(manager.read(withIQ: try response(id: id, body: """
        <x xmlns='jabber:x:data' type='result'>
          <field var='FORM_TYPE' type='hidden'><value>https://xabber.com/protocol/push</value></field>
          <field var='url'><value>https://example.invalid/iq</value></field>
        </x>
        """)))

        XCTAssertTrue(manager.enabled)
        XCTAssertEqual(callbacks, [true])
    }

    func testIQErrorNeverEnablesRegistrationOrPublishesItsHTTPGrant() throws {
        let (manager, stream, node) = fixture()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }
        let id = try requestID(stream)

        XCTAssertTrue(manager.read(withIQ: try response(
            id: id,
            type: "error",
            body: grant() + "<error type='cancel'><forbidden xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>"
        )))

        XCTAssertFalse(manager.enabled)
        XCTAssertEqual(callbacks, [false])
        XCTAssertFalse(manager.queryIds.contains(id))
        XCTAssertTrue(try CredentialsManager.shared.getPushCredentials(for: node).jwt != "fixture-jwt")
    }

    func testWrongSenderDoesNotConsumeCurrentQuery() throws {
        let (manager, stream, _) = fixture()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }
        let id = try requestID(stream)

        XCTAssertFalse(manager.read(withIQ: try response(id: id, from: "other@example.invalid", body: grant())))

        XCTAssertEqual(manager.enableState, .pending(queryId: id))
        XCTAssertTrue(manager.queryIds.contains(id))
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertTrue(manager.read(withIQ: try response(id: id, body: grant())))
        XCTAssertEqual(callbacks, [true])
    }

    func testWrongIQTypeDoesNotConsumeCurrentQuery() throws {
        let (manager, stream, _) = fixture()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }
        let id = try requestID(stream)

        XCTAssertFalse(manager.read(withIQ: try response(id: id, type: "get", body: grant())))

        XCTAssertEqual(manager.enableState, .pending(queryId: id))
        XCTAssertTrue(manager.queryIds.contains(id))
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testWrongIDDoesNotConsumeCurrentQuery() throws {
        let (manager, stream, _) = fixture()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }
        let id = try requestID(stream)

        XCTAssertFalse(manager.read(withIQ: try response(id: "different-query", body: grant())))

        XCTAssertEqual(manager.enableState, .pending(queryId: id))
        XCTAssertTrue(manager.queryIds.contains(id))
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testConfigurationChangeCancelsPendingAndStaleResultCannotReplaceNewCredentials() throws {
        let (manager, stream, _) = fixture()
        var oldCallbacks: [Bool] = []
        var newCallbacks: [Bool] = []
        manager.enable(xmppStream: stream) { oldCallbacks.append($0) }
        let oldID = try requestID(stream)
        let newNode = freshNode()

        manager.configure(node: newNode, service: "new-push.example.invalid")

        XCTAssertEqual(oldCallbacks, [false])
        XCTAssertEqual(manager.enableState, .disabled)
        XCTAssertFalse(manager.queryIds.contains(oldID))
        manager.enable(xmppStream: stream) { newCallbacks.append($0) }
        let newID = try requestID(stream, index: 1)
        XCTAssertFalse(manager.read(withIQ: try response(id: oldID, body: grant())))
        XCTAssertEqual(manager.enableState, .pending(queryId: newID))
        XCTAssertTrue(newCallbacks.isEmpty)
        XCTAssertTrue(try CredentialsManager.shared.getPushCredentials(for: newNode).jwt != "fixture-jwt")
        XCTAssertTrue(manager.read(withIQ: try response(id: newID, body: "")))
        XCTAssertEqual(oldCallbacks, [false])
        XCTAssertEqual(newCallbacks, [true])
    }

    func testServiceChangeOnSameNodeInvalidatesPendingQuery() throws {
        let (manager, stream, node) = fixture()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }
        let id = try requestID(stream)

        manager.configure(node: node, service: "replacement.example.invalid")

        XCTAssertEqual(callbacks, [false])
        XCTAssertEqual(manager.enableState, .disabled)
        XCTAssertFalse(manager.read(withIQ: try response(id: id, body: grant())))
    }

    func testSameConfigurationPreservesOnePendingQueryAndCompletesEachCallerOnce() throws {
        let (manager, stream, node) = fixture()
        var firstCallbacks: [Bool] = []
        var secondCallbacks: [Bool] = []
        manager.enable(xmppStream: stream) { firstCallbacks.append($0) }
        manager.configure(node: node, service: pushService)
        manager.enable(xmppStream: stream) { secondCallbacks.append($0) }
        let id = try requestID(stream)

        XCTAssertEqual(stream.sentElements.count, 1)
        XCTAssertTrue(manager.read(withIQ: try response(id: id, body: grant())))
        XCTAssertFalse(manager.read(withIQ: try response(id: id, body: grant())))
        manager.disable(xmppStream: stream)

        XCTAssertEqual(firstCallbacks, [true])
        XCTAssertEqual(secondCallbacks, [true])
    }

    func testNewEncryptionKeyIsDurableAndQueryableBeforeEnableLeavesTheStream() throws {
        let (manager, stream, node) = fixture()
        var credentialWasAvailableAtSend = false
        var wireKeyMatchedStoredKeyAtSend = false
        var queryWasTrackedAtSend = false
        stream.onSend = { element in
            guard let key = element.element(forName: "enable")?
                .element(forName: "encryption", xmlns: manager.getPrimaryNamespace())?
                .element(forName: "key", xmlns: manager.getPrimaryNamespace())?.stringValue,
                  let credentials = try? CredentialsManager.shared.getPushCredentials(for: node) else {
                return
            }
            credentialWasAvailableAtSend = credentials.jid == self.owner
            wireKeyMatchedStoredKeyAtSend = credentials.keyBytes.map { Data($0) } == Data(base64Encoded: key)
            queryWasTrackedAtSend = element.attributeStringValue(forName: "id")
                .map { manager.queryIds.contains($0) } ?? false
        }

        manager.enable(xmppStream: stream) { _ in }

        XCTAssertTrue(credentialWasAvailableAtSend)
        XCTAssertTrue(wireKeyMatchedStoredKeyAtSend)
        XCTAssertTrue(queryWasTrackedAtSend)
    }

    func testEnableReusesExistingOwnedKeyAndPreservesGrantWhilePending() throws {
        let (manager, stream, node) = fixture()
        let existingSecret = String(repeating: "k", count: 32)
        try store(node: node, secret: existingSecret, jwt: "previous-fixture-jwt")

        manager.enable(xmppStream: stream) { _ in }

        let wireKey = try XCTUnwrap(stream.sentElements.first?
            .element(forName: "enable")?.element(forName: "encryption", xmlns: manager.getPrimaryNamespace())?
            .element(forName: "key", xmlns: manager.getPrimaryNamespace())?.stringValue)
        XCTAssertTrue(Data(base64Encoded: wireKey) == Data(existingSecret.utf8))
        let credentials = try CredentialsManager.shared.getPushCredentials(for: node)
        XCTAssertTrue(credentials.secret == existingSecret)
        XCTAssertEqual(credentials.jwt, "previous-fixture-jwt")
    }

    func testRetryAfterRejectedEnableKeepsExistingNodeKey() throws {
        let (manager, stream, node) = fixture()
        let existingSecret = String(repeating: "r", count: 32)
        try store(node: node, secret: existingSecret)
        manager.enable(xmppStream: stream) { _ in }
        let firstID = try requestID(stream)
        XCTAssertTrue(manager.read(withIQ: try response(id: firstID, type: "error", body: "")))

        manager.enable(xmppStream: stream) { _ in }

        let keys = stream.sentElements.compactMap {
            $0.element(forName: "enable")?.element(forName: "encryption", xmlns: manager.getPrimaryNamespace())?
                .element(forName: "key", xmlns: manager.getPrimaryNamespace())?.stringValue
        }
        XCTAssertEqual(keys.count, 2)
        XCTAssertTrue(keys.allSatisfy { Data(base64Encoded: $0) == Data(existingSecret.utf8) })
    }

    func testBinaryStoredKeyIsEncodedExactlyOnceForSummaryAndFullRegistration() throws {
        let (manager, stream, node) = fixture()
        let bytes = Data(Array(UInt8(0)...UInt8(31)))
        let encodedKey = bytes.base64EncodedString()
        try CredentialsManager.shared.storePushCredentials(
            node: node, jid: owner, host: "example.invalid", secret: encodedKey,
            service: "https://example.invalid/iq", jwt: "previous-fixture-jwt", keyEncoding: .base64
        )
        var mode = PushPayloadMode.summary
        manager.payloadModeProvider = { mode }

        manager.enable(xmppStream: stream) { _ in }
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream), body: "")))
        mode = .full
        manager.enable(xmppStream: stream) { _ in }

        let enables = stream.sentElements.filter { $0.element(forName: "enable", xmlns: manager.getPrimaryNamespace()) != nil }
        XCTAssertEqual(enables.count, 2)
        guard enables.count == 2 else { return }
        for (index, expectedMode) in ["summary", "full"].enumerated() {
            let enable = try XCTUnwrap(enables[index].element(forName: "enable"))
            let key = try XCTUnwrap(enable.element(forName: "encryption", xmlns: manager.getPrimaryNamespace())?
                .element(forName: "key", xmlns: manager.getPrimaryNamespace())?.stringValue)
            XCTAssertEqual(enable.attributeStringValue(forName: "mode"), expectedMode)
            XCTAssertEqual(key, encodedKey)
            XCTAssertEqual(Data(base64Encoded: key), bytes)
        }
        let stored = try CredentialsManager.shared.getPushCredentials(for: node)
        XCTAssertEqual(stored.keyEncoding, .base64)
        XCTAssertEqual(stored.secret, encodedKey)
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream, index: 1), body: "")))
    }

    func testForeignOwnedNodeCredentialsAreNotOverwrittenOrSent() throws {
        let (manager, stream, node) = fixture()
        let foreignOwner = "another-account@example.invalid"
        let existingSecret = String(repeating: "f", count: 32)
        try store(node: node, jid: foreignOwner, secret: existingSecret)
        var callbacks: [Bool] = []

        manager.enable(xmppStream: stream) { callbacks.append($0) }

        XCTAssertTrue(stream.sentElements.isEmpty)
        XCTAssertEqual(callbacks, [false])
        let credentials = try CredentialsManager.shared.getPushCredentials(for: node)
        XCTAssertEqual(credentials.jid, foreignOwner)
        XCTAssertTrue(credentials.secret == existingSecret)
    }

    func testClearSessionCancelsPendingAndRejectsLateResponse() throws {
        let (manager, stream, _) = fixture()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }
        let id = try requestID(stream)

        manager.clearSession()

        XCTAssertEqual(callbacks, [false])
        XCTAssertEqual(manager.enableState, .disabled)
        XCTAssertFalse(manager.queryIds.contains(id))
        XCTAssertFalse(manager.read(withIQ: try response(id: id, body: grant())))
        XCTAssertEqual(callbacks, [false])
    }

    func testDisableIsEmptyAndScopedToAuthenticatedSession() throws {
        let (manager, stream, _) = fixture()

        manager.disable(xmppStream: stream)

        let disable = try XCTUnwrap(stream.sentElements.first?
            .element(forName: "disable", xmlns: manager.getPrimaryNamespace()))
        XCTAssertNil(disable.attributeStringValue(forName: "jid"))
        XCTAssertNil(disable.attributeStringValue(forName: "node"))
        XCTAssertEqual(disable.childCount, 0)
    }

    func testDisableDoesNotRequireLocalNodeOrServiceConfiguration() throws {
        let manager = PushNotificationsManager(withOwner: owner)
        let stream = CapturingStream()
        stream.myJID = XMPPJID(string: "\(owner)/ios-contract")

        manager.disable(xmppStream: stream)

        let iq = try XCTUnwrap(stream.sentElements.first)
        let disable = try XCTUnwrap(iq.element(forName: "disable", xmlns: manager.getPrimaryNamespace()))
        XCTAssertEqual(iq.attributeStringValue(forName: "type"), "set")
        XCTAssertNil(disable.attributeStringValue(forName: "jid"))
        XCTAssertNil(disable.attributeStringValue(forName: "node"))
        XCTAssertEqual(disable.childCount, 0)
    }

    func testDisableCannotUseAnotherAccountsAuthenticatedSession() {
        let (manager, stream, _) = fixture()
        stream.myJID = XMPPJID(string: "another-account@example.invalid/ios-contract")

        manager.disable(xmppStream: stream)

        XCTAssertTrue(stream.sentElements.isEmpty)
    }

    func testImplicitAndAccountBareSendersRemainCompatibleWithActualServer() throws {
        for sender in [nil, owner] as [String?] {
            let (manager, stream, _) = fixture()
            var callbacks: [Bool] = []
            manager.enable(xmppStream: stream) { callbacks.append($0) }
            let id = try requestID(stream)
            let senderAttribute = sender.map { " from='\($0)'" } ?? ""
            let document = try DDXMLDocument(xmlString: "<iq type='result' id='\(id)'\(senderAttribute)/>", options: 0)

            XCTAssertTrue(manager.read(withIQ: XMPPIQ(from: try XCTUnwrap(document.rootElement()))))

            XCTAssertTrue(manager.enabled)
            XCTAssertEqual(callbacks, [true])
        }
    }

    func testForeignResourceAndDomainResourceCannotCompleteRegistration() throws {
        let (manager, stream, _) = fixture()
        manager.enable(xmppStream: stream) { _ in }
        let id = try requestID(stream)

        for sender in ["\(owner)/another-device", "example.invalid/server-resource"] {
            XCTAssertFalse(manager.read(withIQ: try response(id: id, from: sender, body: grant())))
        }

        XCTAssertEqual(manager.enableState, .pending(queryId: id))
    }

    func testMalformedOwnedKeyIsNotSilentlyRotatedOnExistingNode() throws {
        let (manager, stream, node) = fixture()
        let corruptSecret = String(repeating: "k", count: 31)
        try store(node: node, secret: corruptSecret)
        var callbacks: [Bool] = []

        manager.enable(xmppStream: stream) { callbacks.append($0) }

        XCTAssertTrue(stream.sentElements.isEmpty)
        XCTAssertEqual(callbacks, [false])
        XCTAssertTrue(try CredentialsManager.shared.getPushCredentials(for: node).secret == corruptSecret)
    }

    func testFailedDurableKeyWritePreventsSendingRegistration() throws {
        let (manager, stream, _) = fixture()
        manager.credentialReader = { _ in throw CredentialsManager.CredentialsError.itemNotFound }
        manager.credentialWriter = { _, _ in throw CredentialsManager.CredentialsError.pushStorageFailure }
        var callbacks: [Bool] = []

        manager.enable(xmppStream: stream) { callbacks.append($0) }

        XCTAssertTrue(stream.sentElements.isEmpty)
        XCTAssertEqual(callbacks, [false])
        XCTAssertEqual(manager.enableState, .disabled)
    }

    func testTimeoutFinishesOnceAndRetryKeepsKeyAndIgnoresLateOldResult() throws {
        let (manager, stream, node) = fixture()
        let timeouts = ManualTimeouts()
        manager.registrationTimeoutScheduler = timeouts.schedule
        var firstCallbacks: [Bool] = []
        var retryCallbacks: [Bool] = []
        manager.enable(xmppStream: stream) { firstCallbacks.append($0) }
        let firstID = try requestID(stream)
        let firstKey = try CredentialsManager.shared.getPushCredentials(for: node).keyBytes

        timeouts.tasks[0].fire()
        timeouts.tasks[0].fire()

        XCTAssertEqual(firstCallbacks, [false])
        XCTAssertEqual(manager.enableState, .disabled)
        XCTAssertTrue(timeouts.tasks[0].cancelled)
        manager.enable(xmppStream: stream) { retryCallbacks.append($0) }
        let retryID = try requestID(stream, index: 1)
        XCTAssertTrue(try CredentialsManager.shared.getPushCredentials(for: node).keyBytes == firstKey)
        XCTAssertFalse(manager.read(withIQ: try response(id: firstID, body: grant())))
        XCTAssertTrue(manager.read(withIQ: try response(id: retryID, body: "")))
        timeouts.tasks[1].fire()
        XCTAssertEqual(retryCallbacks, [true])
        XCTAssertTrue(manager.enabled)
    }

    func testPushRefreshPreservesModernHTTPGrantAndEncryptionKey() throws {
        let (manager, stream, node) = fixture()
        let grant = modernGrant()
        try store(node: node, secret: String(repeating: "r", count: 32), httpArchive: grant)
        var initialCallbacks: [Bool] = []
        var refreshCallbacks: [Bool] = []
        manager.enable(xmppStream: stream) { initialCallbacks.append($0) }
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream), body: "")))
        let firstKey = try CredentialsManager.shared.getPushCredentials(for: node).keyBytes
        XCTAssertTrue(manager.httpPreviewReady)

        manager.refresh(xmppStream: stream) { refreshCallbacks.append($0) }

        XCTAssertTrue(manager.enabled)
        XCTAssertTrue(manager.httpPreviewReady)
        let refreshKey = try XCTUnwrap(stream.sentElements.filter {
            $0.element(forName: "enable", xmlns: manager.getPrimaryNamespace()) != nil
        }.dropFirst().first?.element(forName: "enable")?.element(forName: "encryption", xmlns: manager.getPrimaryNamespace())?
            .element(forName: "key", xmlns: manager.getPrimaryNamespace())?.stringValue)
        XCTAssertEqual(Data(base64Encoded: refreshKey), firstKey.map { Data($0) })
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream, index: 1), body: self.grant())))
        XCTAssertEqual(initialCallbacks, [true])
        XCTAssertEqual(refreshCallbacks, [true])
        let updated = try CredentialsManager.shared.getPushCredentials(for: node)
        XCTAssertEqual(updated.keyBytes, firstKey)
        XCTAssertEqual(updated.httpArchive, grant, "Legacy inline forms cannot renew an HTTP IQ grant")
    }

    func testFailedRefreshKeepsRegistrationAndExistingModernGrant() throws {
        let (manager, stream, node) = fixture()
        let grant = modernGrant()
        try store(node: node, secret: String(repeating: "r", count: 32), httpArchive: grant)
        let timeouts = ManualTimeouts()
        manager.registrationTimeoutScheduler = timeouts.schedule
        manager.enable(xmppStream: stream) { _ in }
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream), body: "")))
        var callbacks: [Bool] = []

        manager.refresh(xmppStream: stream) { callbacks.append($0) }
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream, index: 1), type: "error", body: "")))
        timeouts.tasks[1].fire()

        XCTAssertEqual(callbacks, [false])
        XCTAssertTrue(manager.enabled)
        XCTAssertTrue(manager.httpPreviewReady)
        XCTAssertEqual(try CredentialsManager.shared.getPushCredentials(for: node).httpArchive, grant)
    }

    func testTimeoutDuringRefreshKeepsRegistrationAndCompletesOnce() throws {
        let (manager, stream, _) = fixture()
        let timeouts = ManualTimeouts()
        manager.registrationTimeoutScheduler = timeouts.schedule
        manager.enable(xmppStream: stream) { _ in }
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream), body: "")))
        var callbacks: [Bool] = []

        manager.refresh(xmppStream: stream) { callbacks.append($0) }
        let id = try requestID(stream, index: 1)
        timeouts.tasks[1].fire()
        timeouts.tasks[1].fire()

        XCTAssertTrue(manager.enabled)
        XCTAssertEqual(callbacks, [false])
        XCTAssertFalse(manager.read(withIQ: try response(id: id, body: grant())))
    }

    func testUnknownCapabilityDefersEnableAndConfirmedOwnerSupportSendsOnce() throws {
        let (manager, stream, _) = fixture()
        let timeouts = ManualTimeouts()
        manager.registrationTimeoutScheduler = timeouts.schedule
        manager.awaitCustomPushSupport()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }
        XCTAssertTrue(stream.sentElements.isEmpty)
        XCTAssertTrue(callbacks.isEmpty)

        manager.setCustomPushSupport(true, xmppStream: stream)
        manager.setCustomPushSupport(true, xmppStream: stream)

        XCTAssertEqual(stream.sentElements.count, 1)
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream), body: "")))
        XCTAssertEqual(callbacks, [true])
    }

    func testUnsupportedCapabilityCancelsDeferredEnableWithoutStandardPushFallback() {
        let (manager, stream, _) = fixture()
        manager.awaitCustomPushSupport()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }

        manager.setCustomPushSupport(false, xmppStream: stream)
        manager.setCustomPushSupport(false, xmppStream: stream)

        XCTAssertTrue(stream.sentElements.isEmpty)
        XCTAssertEqual(callbacks, [false])
        XCTAssertFalse(manager.enabled)
    }

    func testUnknownCapabilityHasBoundedTimeoutAndDoesNotResurrectExpiredRequest() {
        let (manager, stream, _) = fixture()
        let timeouts = ManualTimeouts()
        manager.registrationTimeoutScheduler = timeouts.schedule
        manager.awaitCustomPushSupport()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }

        timeouts.tasks[0].fire()
        manager.setCustomPushSupport(true, xmppStream: stream)

        XCTAssertTrue(stream.sentElements.isEmpty)
        XCTAssertEqual(callbacks, [false])
    }

    func testSynchronousResponseDuringSendSeesTrackedDurableRequest() throws {
        let (manager, stream, _) = fixture()
        var callbacks: [Bool] = []
        var responseWasConsumed = false
        stream.onSend = { element in
            guard let id = element.attributeStringValue(forName: "id"),
                  let result = try? self.response(id: id, body: "") else { return }
            responseWasConsumed = manager.read(withIQ: result)
        }

        manager.enable(xmppStream: stream) { callbacks.append($0) }

        XCTAssertTrue(responseWasConsumed)
        XCTAssertTrue(manager.enabled)
        XCTAssertEqual(callbacks, [true])
    }

    func testLegacyInlineFormsCannotEnableHTTPPreview() throws {
        for body in [
            grant().replacingOccurrences(of: "https://example.invalid/iq", with: "http://example.invalid/iq"),
            grant().replacingOccurrences(of: "https://example.invalid/iq", with: "https://user:password@example.invalid/iq"),
            grant().replacingOccurrences(of: "https://xabber.com/protocol/push</value>", with: "other-form</value>"),
            grant().replacingOccurrences(of: "</x>", with: "<field var='jwt'><value>duplicate</value></field></x>")
        ] {
            let (manager, stream, _) = fixture()
            manager.enable(xmppStream: stream) { _ in }

            XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream), body: body)))

            XCTAssertTrue(manager.enabled)
            XCTAssertFalse(manager.httpPreviewReady)
        }
    }

    func testExplicitForeignRecipientCannotConsumeCurrentRegistration() throws {
        let (manager, stream, _) = fixture()
        var callbacks: [Bool] = []
        manager.enable(xmppStream: stream) { callbacks.append($0) }
        let id = try requestID(stream)

        for recipient in ["another-account@example.invalid/ios-contract", "\(owner)/other-resource"] {
            let document = try DDXMLDocument(
                xmlString: "<iq type='result' id='\(id)' from='example.invalid' to='\(recipient)'>\(grant())</iq>",
                options: 0
            )
            XCTAssertFalse(manager.read(withIQ: XMPPIQ(from: try XCTUnwrap(document.rootElement()))))
        }

        XCTAssertEqual(manager.enableState, .pending(queryId: id))
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertTrue(manager.read(withIQ: try response(id: id, body: "")))
        XCTAssertEqual(callbacks, [true])
    }

    func testUnavailableCredentialReadDoesNotGenerateOrWriteReplacementKey() {
        let (manager, stream, _) = fixture()
        var writeCount = 0
        manager.credentialReader = { _ in throw CredentialsManager.CredentialsError.pushStorageFailure }
        manager.credentialWriter = { _, _ in writeCount += 1 }
        var callbacks: [Bool] = []

        manager.enable(xmppStream: stream) { callbacks.append($0) }

        XCTAssertEqual(writeCount, 0)
        XCTAssertTrue(stream.sentElements.isEmpty)
        XCTAssertEqual(callbacks, [false])
    }

    func testExpiredModernGrantRemainsUnreadyAfterPushOnlyRefresh() throws {
        let (manager, stream, node) = fixture()
        let expired = modernGrant(expiresAt: Date(timeIntervalSince1970: 1))
        try store(node: node, secret: String(repeating: "e", count: 32), httpArchive: expired)
        manager.enable(xmppStream: stream) { _ in }
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream), body: "")))
        let key = try CredentialsManager.shared.getPushCredentials(for: node).keyBytes

        manager.refresh(xmppStream: stream) { _ in }
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream, index: 1), body: grant())))

        XCTAssertTrue(manager.enabled)
        XCTAssertFalse(manager.httpPreviewReady)
        let saved = try CredentialsManager.shared.getPushCredentials(for: node)
        XCTAssertEqual(saved.keyBytes, key)
        XCTAssertEqual(saved.httpArchive, expired)
    }

    func testSimultaneousRefreshCallersShareOneServerIssuanceAndFinishOnce() throws {
        let (manager, stream, _) = fixture()
        manager.enable(xmppStream: stream) { _ in }
        XCTAssertTrue(manager.read(withIQ: try response(id: requestID(stream), body: "")))
        var first: [Bool] = []
        var second: [Bool] = []

        manager.refresh(xmppStream: stream) { first.append($0) }
        manager.refresh(xmppStream: stream) { second.append($0) }
        XCTAssertEqual(stream.sentElements.count, 2)
        let id = try requestID(stream, index: 1)
        XCTAssertTrue(manager.read(withIQ: try response(id: id, body: grant())))
        XCTAssertFalse(manager.read(withIQ: try response(id: id, body: grant())))

        XCTAssertEqual(first, [true])
        XCTAssertEqual(second, [true])
    }

    func testStaleTimerAfterConfigurationChangeCannotFinishReplacementRequest() throws {
        let (manager, stream, _) = fixture()
        let timeouts = ManualTimeouts()
        manager.registrationTimeoutScheduler = timeouts.schedule
        var first: [Bool] = []
        var replacement: [Bool] = []
        manager.enable(xmppStream: stream) { first.append($0) }
        manager.configure(node: freshNode(), service: pushService)
        manager.enable(xmppStream: stream) { replacement.append($0) }
        let replacementID = try requestID(stream, index: 1)

        timeouts.tasks[0].fire()

        XCTAssertTrue(timeouts.tasks[0].cancelled)
        XCTAssertEqual(first, [false])
        XCTAssertTrue(replacement.isEmpty)
        XCTAssertEqual(manager.enableState, .pending(queryId: replacementID))
        XCTAssertTrue(manager.read(withIQ: try response(id: replacementID, body: "")))
        XCTAssertEqual(replacement, [true])
    }

    private func fixture() -> (PushNotificationsManager, CapturingStream, String) {
        let node = freshNode()
        let manager = PushNotificationsManager(withOwner: owner)
        manager.payloadModeProvider = { .full }
        manager.node = node
        manager.service = pushService
        let stream = CapturingStream()
        stream.myJID = XMPPJID(string: "\(owner)/ios-contract")
        return (manager, stream, node)
    }

    private func freshNode() -> String {
        let node = "push-contract-\(UUID().uuidString)"
        nodes.append(node)
        return node
    }

    private func requestID(_ stream: CapturingStream, index: Int = 0) throws -> String {
        let enables = stream.sentElements.filter {
            $0.element(forName: "enable", xmlns: "https://xabber.com/protocol/push") != nil
        }
        XCTAssertGreaterThan(enables.count, index)
        return try XCTUnwrap(enables.dropFirst(index).first?.attributeStringValue(forName: "id"))
    }

    private func store(node: String, jid: String? = nil, secret: String, jwt: String = "", httpArchive: PushHTTPArchiveGrant? = nil) throws {
        try CredentialsManager.shared.storePushCredentials(
            node: node,
            jid: jid ?? owner,
            host: "example.invalid",
            secret: secret,
            service: "https://example.invalid/iq",
            jwt: jwt,
            httpArchive: httpArchive
        )
    }

    private func modernGrant(expiresAt: Date = Date().addingTimeInterval(3600)) -> PushHTTPArchiveGrant {
        PushHTTPArchiveGrant(endpoint: "https://example.invalid/iq/archive/id", token: "header.payload.signature",
                            scopes: ["urn:xmpp:mam:2"], expiresAt: expiresAt, discoveryDomain: "example.invalid")
    }

    private func response(
        id: String,
        type: String = "result",
        from: String = "example.invalid",
        body: String
    ) throws -> XMPPIQ {
        let document = try DDXMLDocument(
            xmlString: "<iq type='\(type)' id='\(id)' from='\(from)' to='\(owner)/ios-contract'>\(body)</iq>",
            options: 0
        )
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func grant() -> String {
        """
        <x xmlns='jabber:x:data' type='result'>
          <field var='FORM_TYPE' type='hidden'><value>https://xabber.com/protocol/push</value></field>
          <field var='url'><value>https://example.invalid/iq</value></field>
          <field var='jwt'><value>fixture-jwt</value></field>
        </x>
        """
    }
}
