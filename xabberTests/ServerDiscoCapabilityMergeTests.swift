import XCTest
import XMPPFramework
import RxSwift
@testable import xabber

final class ServerDiscoCapabilityMergeTests: XCTestCase {
    private var owner: String!
    private var originalNewAccountJID: String!
    private var originalObserver: AccountManager.UserObserver!

    override func setUp() {
        super.setUp()
        owner = "push-capability-\(UUID().uuidString.lowercased())@example.com"
        let manager = AccountManager.shared
        originalNewAccountJID = manager.newAccountJid
        originalObserver = manager.newAccountObservable.value
        manager.users.removeAll()
        manager.newAccountJid = owner
        manager.newAccountObservable.accept(
            AccountManager.UserObserver(jid: owner, state: .auth)
        )
    }

    override func tearDown() {
        let manager = AccountManager.shared
        manager.users.forEach { $0.disco.clearSession() }
        manager.users.removeAll()
        manager.newAccountJid = originalNewAccountJID
        manager.newAccountObservable.accept(originalObserver)
        SettingManager.shared.removeItem(for: owner, scope: .httpUploader, key: "node")
        originalObserver = nil
        originalNewAccountJID = nil
        owner = nil
        super.tearDown()
    }

    func testBareJIDPushCapabilitiesMergeIntoRootCapabilitiesWithoutExtraWait() throws {
        let (account, stream) = makeAccountAndConfigureDiscovery()
        let bareQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: owner))
        let rootQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: "example.com"))

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: bareQueryID,
                    from: owner,
                    features: ["urn:xmpp:push:0", "https://xabber.com/protocol/push"]
                )
            )
        )
        assertOnboardingIsStillAuthenticating()

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: rootQueryID,
                    from: "example.com",
                    features: ["urn:xmpp:mam:2", "http://jabber.org/protocol/pubsub"]
                )
            )
        )

        let capabilities = try terminalCapabilities()
        XCTAssertTrue(capabilities.contains("mam"))
        XCTAssertTrue(capabilities.contains("pubsub"))
        XCTAssertTrue(capabilities.contains("push"))
        XCTAssertTrue(capabilities.contains("xpush"))
        XCTAssertFalse(capabilities.contains(ServerDiscoManager.retryableServerCapabilitiesMarker))
    }

    func testRootResponseWaitsOnlyForInFlightBareJIDCapabilityResponse() throws {
        let (account, stream) = makeAccountAndConfigureDiscovery()
        let bareQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: owner))
        let rootQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: "example.com"))

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: rootQueryID,
                    from: "example.com",
                    features: ["urn:xmpp:mam:2"]
                )
            )
        )
        assertOnboardingIsStillAuthenticating()

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: bareQueryID,
                    from: owner,
                    features: ["https://xabber.com/protocol/push"]
                )
            )
        )

        let capabilities = try terminalCapabilities()
        XCTAssertTrue(capabilities.contains("mam"))
        XCTAssertTrue(capabilities.contains("xpush"))
        XCTAssertFalse(capabilities.contains(ServerDiscoManager.retryableServerCapabilitiesMarker))
    }

    func testMissingBareJIDResponseReleasesOnboardingAsRetryableWithinBoundedGrace() throws {
        let (account, stream) = makeAccountAndConfigureDiscovery()
        let bareQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: owner))
        let rootQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: "example.com"))
        let released = expectation(description: "bounded bare-JID capability grace releases onboarding")
        let subscription = AccountManager.shared.newAccountObservable
            .skip(1)
            .subscribe(onNext: { observer in
                if case .capsReceived = observer.state {
                    released.fulfill()
                }
            })
        defer { subscription.dispose() }

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: rootQueryID,
                    from: "example.com",
                    features: ["urn:xmpp:mam:2"]
                )
            )
        )
        assertOnboardingIsStillAuthenticating()

        wait(for: [released], timeout: 1)

        let capabilities = try terminalCapabilities()
        XCTAssertTrue(capabilities.contains("mam"))
        XCTAssertTrue(capabilities.contains(ServerDiscoManager.retryableServerCapabilitiesMarker))
        XCTAssertFalse(capabilities.contains("xpush"))
        XCTAssertFalse(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: bareQueryID,
                    from: owner,
                    features: ["https://xabber.com/protocol/push"]
                )
            ),
            "A late bare-JID response must not publish a second onboarding snapshot"
        )
    }

    func testProductionGraceDoesNotAddPerceptibleOnboardingDelay() {
        XCTAssertLessThanOrEqual(
            ServerDiscoManager.defaultAccountOwnerCapabilityGraceInterval,
            0.1
        )
    }

    func testOnlyTrackedBareJIDCanAuthorizePushCapabilities() throws {
        let (account, stream) = makeAccountAndConfigureDiscovery()
        let bareQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: owner))
        let rootQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: "example.com"))
        let contactQueryID = "contact-disco-\(UUID().uuidString)"
        account.disco.queryIds.insert(contactQueryID)

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: contactQueryID,
                    from: "contact@example.net/phone",
                    features: ["https://xabber.com/protocol/push"]
                )
            )
        )
        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: bareQueryID,
                    from: owner,
                    features: ["urn:xmpp:mam:2"]
                )
            )
        )
        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: rootQueryID,
                    from: "example.com",
                    features: ["urn:xmpp:mam:2", "https://xabber.com/protocol/push"]
                )
            )
        )

        let capabilities = try terminalCapabilities()
        XCTAssertTrue(capabilities.contains("mam"))
        XCTAssertFalse(capabilities.contains("push"))
        XCTAssertFalse(capabilities.contains("xpush"))
        XCTAssertFalse(capabilities.contains(ServerDiscoManager.retryableServerCapabilitiesMarker))
    }

    func testCachedUploaderDoesNotSuppressBareJIDCapabilityDiscovery() {
        SettingManager.shared.saveItem(
            for: owner,
            scope: .httpUploader,
            key: "node",
            value: "upload.example.com"
        )

        let (_, stream) = makeAccountAndConfigureDiscovery()

        XCTAssertNotNil(stream.discoInfoRequestID(to: owner))
    }

    func testRepeatedConfigureKeepsOneCoherentCapabilityDiscoveryPair() throws {
        let (account, stream) = makeAccountAndConfigureDiscovery()

        account.disco.configure(stream)

        XCTAssertEqual(stream.discoInfoRequestCount(to: owner), 1)
        XCTAssertEqual(stream.discoInfoRequestCount(to: "example.com"), 1)
        let bareQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: owner))
        let rootQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: "example.com"))

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: bareQueryID,
                    from: owner,
                    features: ["https://xabber.com/protocol/push"]
                )
            )
        )
        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: rootQueryID,
                    from: "example.com",
                    features: ["urn:xmpp:mam:2"]
                )
            )
        )

        let capabilities = try terminalCapabilities()
        XCTAssertTrue(capabilities.contains("mam"))
        XCTAssertTrue(capabilities.contains("xpush"))
    }

    func testConfigureAttachesBareJIDToAlreadyActiveRootDiscovery() throws {
        let account = makeAccount(graceInterval: 0.02)
        let stream = ServerDiscoCapabilityCapturingStream()
        stream.myJID = XMPPJID(string: owner, resource: "ios")
        account.disco.requestServerFeatures(stream)
        let rootQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: "example.com"))

        account.disco.configure(stream)

        XCTAssertEqual(stream.discoInfoRequestCount(to: owner), 1)
        XCTAssertEqual(stream.discoInfoRequestCount(to: "example.com"), 1)
        let bareQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: owner))
        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: bareQueryID,
                    from: owner,
                    features: ["https://xabber.com/protocol/push"]
                )
            )
        )
        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: rootQueryID,
                    from: "example.com",
                    features: ["urn:xmpp:mam:2"]
                )
            )
        )

        let capabilities = try terminalCapabilities()
        XCTAssertTrue(capabilities.contains("mam"))
        XCTAssertTrue(capabilities.contains("xpush"))
    }

    func testResetStreamCancelsOldPairBeforeStartingNewCapabilityDiscovery() throws {
        let account = makeAccount(graceInterval: 0.02)
        let oldStream = ServerDiscoCapabilityCapturingStream()
        oldStream.myJID = XMPPJID(string: owner, resource: "old-ios")
        account.disco.configure(oldStream)
        let oldBareQueryID = try XCTUnwrap(oldStream.discoInfoRequestID(to: owner))
        let oldRootQueryID = try XCTUnwrap(oldStream.discoInfoRequestID(to: "example.com"))

        account.resetStream()
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .retryableFailure(stage: .disconnected, endpoint: nil)
        )
        AccountManager.shared.newAccountJid = owner
        AccountManager.shared.newAccountObservable.accept(
            AccountManager.UserObserver(jid: owner, state: .auth)
        )

        let newStream = ServerDiscoCapabilityCapturingStream()
        newStream.myJID = XMPPJID(string: owner, resource: "new-ios")
        account.disco.configure(newStream)
        let newBareQueryID = try XCTUnwrap(newStream.discoInfoRequestID(to: owner))
        let newRootQueryID = try XCTUnwrap(newStream.discoInfoRequestID(to: "example.com"))

        XCTAssertNotEqual(newBareQueryID, oldBareQueryID)
        XCTAssertNotEqual(newRootQueryID, oldRootQueryID)
        XCTAssertFalse(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: oldRootQueryID,
                    from: "example.com",
                    features: ["urn:xmpp:mam:2"]
                )
            )
        )
        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: newBareQueryID,
                    from: owner,
                    features: ["https://xabber.com/protocol/push"]
                )
            )
        )
        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: newRootQueryID,
                    from: "example.com",
                    features: ["urn:xmpp:mam:2"]
                )
            )
        )

        let capabilities = try terminalCapabilities()
        XCTAssertTrue(capabilities.contains("mam"))
        XCTAssertTrue(capabilities.contains("xpush"))
    }

    func testBareJIDErrorReleasesPendingRootImmediatelyAsRetryable() throws {
        let (account, stream) = makeAccountAndConfigureDiscovery(graceInterval: 0.25)
        let bareQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: owner))
        let rootQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: "example.com"))

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: rootQueryID,
                    from: "example.com",
                    features: ["urn:xmpp:mam:2"]
                )
            )
        )
        assertOnboardingIsStillAuthenticating()

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoError(id: bareQueryID, from: owner)
            )
        )

        let capabilities = try terminalCapabilities()
        XCTAssertTrue(capabilities.contains("mam"))
        XCTAssertTrue(capabilities.contains(ServerDiscoManager.retryableServerCapabilitiesMarker))
    }

    func testDisconnectDuringBareJIDGraceReleasesOnceAndRejectsLateResponse() throws {
        let (account, stream) = makeAccountAndConfigureDiscovery(graceInterval: 0.25)
        let bareQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: owner))
        let rootQueryID = try XCTUnwrap(stream.discoInfoRequestID(to: "example.com"))

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: rootQueryID,
                    from: "example.com",
                    features: ["urn:xmpp:mam:2"]
                )
            )
        )
        assertOnboardingIsStillAuthenticating()

        account.disco.clearSession()

        let capabilities = try terminalCapabilities()
        XCTAssertTrue(capabilities.contains("mam"))
        XCTAssertTrue(capabilities.contains(ServerDiscoManager.retryableServerCapabilitiesMarker))
        XCTAssertFalse(
            account.disco.read(
                withIQ: try makeDiscoResult(
                    id: bareQueryID,
                    from: owner,
                    features: ["https://xabber.com/protocol/push"]
                )
            )
        )
    }

    private func makeAccountAndConfigureDiscovery(
        graceInterval: TimeInterval = 0.02
    ) -> (Account, ServerDiscoCapabilityCapturingStream) {
        let account = makeAccount(graceInterval: graceInterval)
        let stream = ServerDiscoCapabilityCapturingStream()
        stream.myJID = XMPPJID(string: owner, resource: "ios")

        account.disco.configure(stream)

        return (account, stream)
    }

    private func makeAccount(graceInterval: TimeInterval) -> Account {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "ServerDiscoCapabilityMergeTests.\(UUID().uuidString)")
        )
        AccountManager.shared.users.append(account)
        account.disco.accountOwnerCapabilityGraceInterval = graceInterval
        return account
    }

    private func makeDiscoResult(
        id: String,
        from: String,
        features: [String]
    ) throws -> XMPPIQ {
        let featureXML = features
            .map { "<feature var=\"\($0)\" />" }
            .joined()
        let document = try DDXMLDocument(
            xmlString: """
            <iq type="result" id="\(id)" from="\(from)">
              <query xmlns="http://jabber.org/protocol/disco#info">
                \(featureXML)
              </query>
            </iq>
            """,
            options: 0
        )
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func makeDiscoError(id: String, from: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(
            xmlString: """
            <iq type="error" id="\(id)" from="\(from)">
              <error type="wait">
                <remote-server-timeout xmlns="urn:ietf:params:xml:ns:xmpp-stanzas" />
              </error>
            </iq>
            """,
            options: 0
        )
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func assertOnboardingIsStillAuthenticating(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .auth = AccountManager.shared.newAccountObservable.value.state else {
            return XCTFail("Capability merge must not complete from an incomplete authority set", file: file, line: line)
        }
    }

    private func terminalCapabilities() throws -> [String] {
        guard case .capsReceived(let capabilities) = AccountManager.shared.newAccountObservable.value.state else {
            throw ServerDiscoCapabilityMergeTestError.missingTerminalCapabilities
        }
        return capabilities
    }
}

private enum ServerDiscoCapabilityMergeTestError: Error {
    case missingTerminalCapabilities
}

private final class ServerDiscoCapabilityCapturingStream: XMPPStream {
    private var discoInfoRequestIDs: [String: String] = [:]
    private var discoInfoRequestTargets: [String] = []

    override func send(_ element: DDXMLElement) {
        guard element.element(forName: "query")?.xmlns() == "http://jabber.org/protocol/disco#info",
              let target = element.attributeStringValue(forName: "to"),
              let elementID = element.attributeStringValue(forName: "id") else {
            return
        }
        discoInfoRequestIDs[target] = elementID
        discoInfoRequestTargets.append(target)
    }

    func discoInfoRequestID(to target: String) -> String? {
        discoInfoRequestIDs[target]
    }

    func discoInfoRequestCount(to target: String) -> Int {
        discoInfoRequestTargets.filter { $0 == target }.count
    }
}
