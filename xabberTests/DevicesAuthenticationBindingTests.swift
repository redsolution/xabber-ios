import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

/// Executes real primary authentication selection and current-session proof
/// boundaries without opening sockets or modifying a real account.
final class DevicesAuthenticationBindingTests: XCTestCase {
    private final class Stream: XMPPStream {
        var mechanisms: Set<String> = []
        var authenticated = true
        var disconnected = false
        var passwordCalls = 0
        var authenticationCalls = 0
        var failAuthentication = false
        var registrationFlags: [(device: Bool, token: Bool)] = []
        var elements: [DDXMLElement] = []
        override var isAuthenticated: Bool { authenticated }
        override var isConnected: Bool { !disconnected }
        override var isDisconnected: Bool { disconnected }
        override func supportsAuthenticationMechanism(_ mechanism: String) -> Bool { mechanisms.contains(mechanism) }
        override func authenticate(withPassword password: String) throws {
            passwordCalls += 1
            registrationFlags.append((shouldRegisterDevice, shouldRequestXToken))
            if failAuthentication { throw NSError(domain: "devices-test", code: 1) }
        }
        override func authenticate(_ auth: XMPPSASLAuthentication) throws {
            authenticationCalls += 1
            if failAuthentication { throw NSError(domain: "devices-test", code: 1) }
        }
        override func send(_ element: DDXMLElement) { elements.append(element.copy() as! DDXMLElement) }
    }

    private var previousRealm: Realm.Configuration!
    private var keeper: Realm!
    private var previousUsers: [Account] = []
    private var previousActiveUsers: Set<String> = []
    private var previousAuthenticatedUsers: Set<String> = []
    private var previousConnectingUsers: Set<String> = []
    private var accounts: [Account] = []
    private var owner = ""

    override func setUpWithError() throws {
        try XCTSkipUnless(HostedXCTestIsolationPolicy.isEnabled(environment: ProcessInfo.processInfo.environment),
            "This suite requires isolated hosted storage and disabled autoconnect")
        previousRealm = Realm.Configuration.defaultConfiguration
        previousUsers = AccountManager.shared.users
        previousActiveUsers = AccountManager.shared.activeUsers.value
        previousAuthenticatedUsers = AccountManager.shared.authenticatedUsers.value
        previousConnectingUsers = AccountManager.shared.connectingUsers.value
        owner = "devices-auth-\(UUID().uuidString.lowercased())@example.test"
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: owner)
        keeper = try WRealm.safe()
        let account = AccountStorageItem()
        account.jid = owner
        account.username = "devices-auth"
        account.enabled = true
        account.deviceUuid = "cached-device"
        try keeper.write { keeper.add(account) }
    }

    override func tearDownWithError() throws {
        guard previousRealm != nil else { return }
        for account in accounts {
            account.queue.sync {}
            account.cancelStartupTrafficOrdering()
            account.cancelDelayedConnectTimer()
            account.xmppTaskScheduler.reset()
            account.messages.updateSendingMessagesTimer?.invalidate()
            account.messages.updateSendingMessagesTimer = nil
            account.omemo.omemo2MaintenanceWorkItem?.cancel()
            account.omemo.omemo2MaintenanceWorkItem = nil
        }
        accounts.removeAll()
        AccountManager.shared.users = previousUsers
        AccountManager.shared.activeUsers.accept(previousActiveUsers)
        AccountManager.shared.authenticatedUsers.accept(previousAuthenticatedUsers)
        AccountManager.shared.connectingUsers.accept(previousConnectingUsers)
        CredentialsManager.shared.getItem(for: owner).release(.authFailedRecoverable)
        keeper = nil
        Realm.Configuration.defaultConfiguration = previousRealm
        previousRealm = nil
        try super.tearDownWithError()
    }

    private func stream(resource: String = "current") -> Stream {
        let value = Stream()
        value.myJID = XMPPJID(string: owner + "/" + resource)
        return value
    }

    private func account(stream: Stream) -> Account {
        let value = Account(jid: owner, queue: DispatchQueue(label: owner))
        value.xmppStream = stream
        value.sendReadiness.onReadinessChanged = nil
        AccountManager.shared.users = previousUsers + [value]
        accounts.append(value)
        return value
    }

    func testPrimaryPasswordAuthenticationRegistersOnOCRAOnlyServerBeforeTokenFallback() throws {
        let wire = stream()
        wire.authenticated = false
        wire.mechanisms = ["DEVICES-OCRA", "X-TOKEN"]
        let account = account(stream: wire)
        CredentialsManager.shared.getItem(for: owner).storePassword("fixture-password")

        account.xmppStreamDidConnect(wire)

        XCTAssertEqual(wire.passwordCalls, 1)
        XCTAssertEqual(wire.registrationFlags.count, 1)
        XCTAssertTrue(wire.registrationFlags.first?.device == true)
        XCTAssertTrue(wire.registrationFlags.first?.token == false)
    }

    func testLegacyHOTPPasswordRegistrationAndStandardTokenFallbackRemainDistinct() {
        let wire = stream()
        wire.authenticated = false
        let account = account(stream: wire)
        CredentialsManager.shared.getItem(for: owner).storePassword("fixture-password")
        wire.mechanisms = ["HOTP", "X-TOKEN"]
        account.xmppStreamDidConnect(wire)
        XCTAssertTrue(wire.registrationFlags.last?.device == true)
        XCTAssertTrue(wire.registrationFlags.last?.token == false)
        wire.mechanisms = ["X-TOKEN"]
        account.xmppStreamDidConnect(wire)
        XCTAssertTrue(wire.registrationFlags.last?.device == false)
        XCTAssertTrue(wire.registrationFlags.last?.token == true)
    }

    func testCachedUUIDAndDevicesAvailabilityAreNotAuthenticatedBindingProof() {
        let manager = XMPPDeviceManager(withOwner: owner)
        let wire = stream()
        XCTAssertTrue(manager.isAvailable)
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
        XCTAssertNil(manager.authenticatedSessionGeneration(on: wire))
        XCTAssertFalse(manager.authenticatedLegacyHOTP(on: wire))
    }

    func testSuccessfulCurrentDeviceAuthenticationBindsExactStreamAndBoundResource() throws {
        let manager = XMPPDeviceManager(withOwner: owner)
        let wire = stream()
        manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)

        XCTAssertEqual(manager.authenticatedDeviceID(on: wire), "accepted-device")
        XCTAssertNotNil(manager.authenticatedSessionGeneration(on: wire))
        XCTAssertNil(manager.authenticatedDeviceID(on: stream()))
        XCTAssertEqual(manager.authenticatedDeviceID(on: wire), "accepted-device")
        wire.myJID = XMPPJID(string: owner + "/replacement-resource")
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
        wire.myJID = XMPPJID(string: owner + "/current")
        XCTAssertNil(manager.authenticatedDeviceID(on: wire), "A changed resource revokes prior proof permanently")
    }

    func testWrongOwnerMissingResourceAndUnauthenticatedInputCannotBind() {
        let manager = XMPPDeviceManager(withOwner: owner)
        let wire = stream()
        wire.myJID = XMPPJID(string: "foreign@example.test/current")
        manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
        wire.myJID = XMPPJID(string: owner)
        manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
        wire.myJID = XMPPJID(string: owner + "/current")
        wire.authenticated = false
        manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
        wire.authenticated = true
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
    }

    func testInvalidFreshAuthenticationInputPermanentlyRevokesPreviouslyAcceptedProof() {
        for invalid in ["wrong-owner", "missing-resource", "not-authenticated"] {
            let manager = XMPPDeviceManager(withOwner: owner)
            let wire = stream()
            manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
            XCTAssertEqual(manager.authenticatedDeviceID(on: wire), "accepted-device")
            if invalid == "wrong-owner" { wire.myJID = XMPPJID(string: "foreign@example.test/current") }
            if invalid == "missing-resource" { wire.myJID = XMPPJID(string: owner) }
            if invalid == "not-authenticated" { wire.authenticated = false }
            manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
            wire.myJID = XMPPJID(string: owner + "/current")
            wire.authenticated = true
            XCTAssertNil(manager.authenticatedDeviceID(on: wire), invalid)
            XCTAssertNil(manager.authenticatedSessionGeneration(on: wire), invalid)
        }
    }

    func testFreshAuthenticationWithoutDeviceProofRevokesPreviousBinding() {
        let manager = XMPPDeviceManager(withOwner: owner)
        let wire = stream()
        manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
        manager.recordAuthenticatedSession(on: wire, deviceID: nil, didResume: false)
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
        XCTAssertNil(manager.authenticatedSessionGeneration(on: wire))
    }

    func testSMResumeRetainsOnlyPreviousSuccessfulSameStreamAndResourceBinding() throws {
        let manager = XMPPDeviceManager(withOwner: owner)
        let wire = stream()
        manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
        let generation = try XCTUnwrap(manager.authenticatedSessionGeneration(on: wire))
        wire.authenticated = false
        wire.disconnected = true
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
        wire.authenticated = true
        wire.disconnected = false
        manager.recordAuthenticatedSession(on: wire, deviceID: nil, didResume: true)
        XCTAssertEqual(manager.authenticatedDeviceID(on: wire), "accepted-device")
        XCTAssertEqual(manager.authenticatedSessionGeneration(on: wire), generation)
        let replacement = stream()
        manager.recordAuthenticatedSession(on: replacement, deviceID: "accepted-device", didResume: true)
        XCTAssertNil(manager.authenticatedDeviceID(on: replacement), "Resume cannot manufacture a new accepted session")
    }

    func testFullReauthenticationReplacesGenerationEvenWhenStreamUUIDAndResourceMatch() throws {
        let manager = XMPPDeviceManager(withOwner: owner)
        let wire = stream()
        manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
        let previous = try XCTUnwrap(manager.authenticatedSessionGeneration(on: wire))
        manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
        XCTAssertNotEqual(manager.authenticatedSessionGeneration(on: wire), previous)
        manager.clearSession()
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
    }

    func testRegistrationResultSeedsCandidateOnlyAfterExactOwnedResultAndBoundAuthentication() throws {
        let manager = XMPPDeviceManager(withOwner: owner)
        let wire = stream()
        wire.authenticated = false
        manager.beginDeviceRegistration(on: wire, requestID: "owned-registration")
        XCTAssertNil(manager.registeredDeviceID(on: wire))
        XCTAssertTrue(manager.read(withIQ: try registrationResult(id: "owned-registration")))
        XCTAssertEqual(manager.registeredDeviceID(on: wire), "registered-device")
        XCTAssertNil(manager.authenticatedDeviceID(on: wire))
        wire.authenticated = true
        manager.recordAuthenticatedSession(on: wire, deviceID: manager.registeredDeviceID(on: wire), didResume: false)
        XCTAssertEqual(manager.authenticatedDeviceID(on: wire), "registered-device")
        XCTAssertNil(manager.registeredDeviceID(on: wire), "Successful binding consumes its pre-bind registration candidate")
    }

    func testRegistrationCandidateRejectsUnownedWrongSenderAndErrorResponses() throws {
        let manager = XMPPDeviceManager(withOwner: owner)
        let wire = stream()
        manager.beginDeviceRegistration(on: wire, requestID: "owned-registration")
        XCTAssertFalse(manager.read(withIQ: try registrationResult(id: "unowned")))
        XCTAssertFalse(manager.read(withIQ: try registrationResult(id: "owned-registration", from: "foreign@example.test")))
        XCTAssertFalse(manager.read(withIQ: try registrationResult(id: "owned-registration", type: "set")))
        XCTAssertNil(manager.registeredDeviceID(on: wire))
        let error = try XMPPIQ(xmlString: "<iq type='error' id='owned-registration'><error type='cancel'><not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
        _ = manager.read(withIQ: error)
        XCTAssertNil(manager.registeredDeviceID(on: wire))
    }

    func testOCRASelectionCapturesActualDeviceUUIDUntilSuccessThenClearsIt() throws {
        let wire = stream()
        wire.mechanisms = ["DEVICES-OCRA"]
        let tracker = XMPPAuthenticationCounterTracker()
        let storage = CredentialsManager.shared.getItem(for: owner)
        storage.storeSecret("fixture-secret", validationKey: "fixture-validation")
        XCTAssertEqual(try XMPPStoredCredentialAuthenticator.authenticate(stream: wire,
            storage: storage, ownerJID: owner, counterTracker: tracker), .started)
        XCTAssertEqual(wire.authenticationCalls, 1)
        XCTAssertEqual(tracker.pendingDevicesDeviceID, "cached-device")
        tracker.authenticationDidSucceed(using: storage)
        XCTAssertNil(tracker.pendingDevicesDeviceID)
    }

    func testOCRAStartFailureAndSubsequentNonDeviceAttemptClearPendingBinding() throws {
        let wire = stream()
        wire.mechanisms = ["DEVICES-OCRA"]
        let tracker = XMPPAuthenticationCounterTracker()
        let storage = CredentialsManager.shared.getItem(for: owner)
        storage.storeSecret("fixture-secret", validationKey: "fixture-validation")
        _ = try XMPPStoredCredentialAuthenticator.authenticate(stream: wire, storage: storage,
            ownerJID: owner, counterTracker: tracker)
        XCTAssertEqual(tracker.pendingDevicesDeviceID, "cached-device")
        wire.failAuthentication = true
        XCTAssertThrowsError(try XMPPStoredCredentialAuthenticator.authenticate(stream: wire,
            storage: storage, ownerJID: owner, counterTracker: tracker))
        XCTAssertNil(tracker.pendingDevicesDeviceID)
        wire.failAuthentication = false
        storage.storeToken("fixture-token")
        wire.mechanisms.insert("X-TOKEN")
        _ = try XMPPStoredCredentialAuthenticator.authenticate(stream: wire, storage: storage,
            ownerJID: owner, counterTracker: tracker)
        XCTAssertNil(tracker.pendingDevicesDeviceID)
    }

    func testPrimaryDidAuthenticateCapturesOCRAProofBeforeCounterSuccessClearsIt() throws {
        let wire = stream()
        wire.mechanisms = ["DEVICES-OCRA"]
        let account = account(stream: wire)
        account.syncManager.isAvailable = true // Defer automatic push/background work.
        let storage = CredentialsManager.shared.getItem(for: owner)
        storage.storeSecret("fixture-secret", validationKey: "fixture-validation")
        _ = try XMPPStoredCredentialAuthenticator.authenticate(stream: wire, storage: storage,
            ownerJID: owner, counterTracker: account.authenticationCounterTracker)
        XCTAssertEqual(account.authenticationCounterTracker.pendingDevicesDeviceID, "cached-device")

        account.xmppStreamDidAuthenticate(wire)

        XCTAssertEqual(account.devices.authenticatedDeviceID(on: wire), "cached-device")
        XCTAssertNil(account.authenticationCounterTracker.pendingDevicesDeviceID)
    }

    func testPrimaryRegistrationCallbacksBindOnlyAcknowledgedCandidateAfterDidAuthenticate() throws {
        let wire = stream()
        wire.mechanisms = ["DEVICES-OCRA"]
        wire.authenticated = false
        let account = account(stream: wire)
        account.syncManager.isAvailable = true
        CredentialsManager.shared.getItem(for: owner).storePassword("fixture-password")
        account.xmppStreamDidConnect(wire)
        account.xmppStreamRequestDeviceRegistration("current-registration")
        account.xmppStreamResponseDeviceRegistration(try registrationResult(id: "current-registration"))
        XCTAssertNil(account.devices.authenticatedDeviceID(on: wire))
        wire.authenticated = true

        account.xmppStreamDidAuthenticate(wire)

        XCTAssertEqual(account.devices.authenticatedDeviceID(on: wire), "registered-device")
        XCTAssertNil(account.devices.registeredDeviceID(on: wire))
    }

    func testCurrentPrimarySASLFailureCannotRevivePreviousBindingOnSameObjectAndResource() throws {
        let wire = stream()
        let account = account(stream: wire)
        CredentialsManager.shared.getItem(for: owner).storePassword("fixture-password")
        account.devices.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
        XCTAssertEqual(account.devices.authenticatedDeviceID(on: wire), "accepted-device")
        wire.authenticated = false
        let failure = try DDXMLElement(xmlString: "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><temporary-auth-failure/></failure>")

        account.xmppStream(wire, didNotAuthenticate: failure)

        wire.authenticated = true
        XCTAssertNil(account.devices.authenticatedDeviceID(on: wire))
        account.devices.recordAuthenticatedSession(on: wire, deviceID: nil, didResume: true)
        XCTAssertNil(account.devices.authenticatedDeviceID(on: wire), "A failed authentication is not a resumable accepted session")
    }

    func testActualHOTPSelectionAndPrimarySuccessRetainLegacyModeWithoutInventingUUID() throws {
        let wire = stream()
        wire.mechanisms = ["HOTP"]
        let account = account(stream: wire)
        account.syncManager.isAvailable = true
        let storage = CredentialsManager.shared.getItem(for: owner)
        storage.storeSecret("fixture-secret", validationKey: "fixture-validation")
        _ = try XMPPStoredCredentialAuthenticator.authenticate(stream: wire, storage: storage,
            ownerJID: owner, counterTracker: account.authenticationCounterTracker)
        XCTAssertEqual(wire.authenticationCalls, 1)
        XCTAssertTrue(account.authenticationCounterTracker.pendingUsesLegacyHOTP)
        XCTAssertNil(account.authenticationCounterTracker.pendingDevicesDeviceID)

        account.xmppStreamDidAuthenticate(wire)

        XCTAssertTrue(account.devices.authenticatedLegacyHOTP(on: wire))
        XCTAssertNil(account.devices.authenticatedDeviceID(on: wire), "Cached UUID was not sent in legacy HOTP")
        XCTAssertNotNil(account.devices.authenticatedSessionGeneration(on: wire))
        XCTAssertFalse(account.authenticationCounterTracker.pendingUsesLegacyHOTP)
        let other = stream(resource: "other")
        XCTAssertFalse(account.devices.authenticatedLegacyHOTP(on: other))
        wire.myJID = XMPPJID(string: owner + "/changed")
        XCTAssertFalse(account.devices.authenticatedLegacyHOTP(on: wire))
        wire.myJID = XMPPJID(string: owner + "/current")
        XCTAssertFalse(account.devices.authenticatedLegacyHOTP(on: wire))
    }

    func testHOTPAttemptFailureAndNextNonDeviceAttemptClearItsTransientMode() throws {
        let wire = stream()
        wire.mechanisms = ["HOTP"]
        let tracker = XMPPAuthenticationCounterTracker()
        let storage = CredentialsManager.shared.getItem(for: owner)
        storage.storeSecret("fixture-secret", validationKey: "fixture-validation")
        _ = try XMPPStoredCredentialAuthenticator.authenticate(stream: wire, storage: storage,
            ownerJID: owner, counterTracker: tracker)
        XCTAssertTrue(tracker.pendingUsesLegacyHOTP)
        tracker.authenticationDidFail()
        XCTAssertFalse(tracker.pendingUsesLegacyHOTP)
        _ = try XMPPStoredCredentialAuthenticator.authenticate(stream: wire, storage: storage,
            ownerJID: owner, counterTracker: tracker)
        storage.storeToken("fixture-token")
        wire.mechanisms.insert("X-TOKEN")
        _ = try XMPPStoredCredentialAuthenticator.authenticate(stream: wire, storage: storage,
            ownerJID: owner, counterTracker: tracker)
        XCTAssertFalse(tracker.pendingUsesLegacyHOTP)
        XCTAssertNil(tracker.pendingDevicesDeviceID)
    }

    func testUnownedWrongTypeSenderAndRecipientDeviceListsCannotMutateProjection() throws {
        let wire = stream()
        let manager = XMPPDeviceManager(withOwner: owner)
        let previous = DeviceStorageItem()
        previous.owner = owner
        previous.uid = "existing-device"
        previous.primary = DeviceStorageItem.genPrimary(uid: previous.uid, owner: owner)
        try keeper.write { keeper.add(previous) }
        manager.requestList(wire)
        let request = try XCTUnwrap(wire.elements.last)
        let id = try XCTUnwrap(request.attributeStringValue(forName: "id"))
        let replies = [
            try deviceListResult(id: "unowned", type: "result", from: "example.test", to: owner + "/current"),
            try deviceListResult(id: id, type: "set", from: "example.test", to: owner + "/current"),
            try deviceListResult(id: id, type: "result", from: "foreign@example.test", to: owner + "/current"),
            try deviceListResult(id: id, type: "result", from: "example.test", to: owner + "/other-resource")
        ]
        for reply in replies {
            XCTAssertFalse(manager.read(withIQ: reply, on: wire))
            XCTAssertEqual(keeper.objects(DeviceStorageItem.self).filter("owner == %@", owner).map(\.uid), ["existing-device"])
        }
        XCTAssertTrue(manager.read(withIQ: try deviceListResult(id: id, type: "result",
            from: "example.test", to: owner + "/current"), on: wire))
        XCTAssertEqual(keeper.objects(DeviceStorageItem.self).filter("owner == %@", owner).map(\.uid), ["listed-device"])
        XCTAssertFalse(manager.read(withIQ: try deviceListResult(id: id, type: "result",
            from: "example.test", to: owner + "/current"), on: wire), "A consumed owner result is not replayable authority")
    }

    func testOwnedDeviceListCannotCrossStreamOrAuthenticationAttempt() throws {
        let wire = stream()
        let manager = XMPPDeviceManager(withOwner: owner)
        manager.beginAuthentication(on: wire)
        manager.requestList(wire)
        let firstID = try XCTUnwrap(wire.elements.last?.attributeStringValue(forName: "id"))
        let old = try deviceListResult(id: firstID, type: "result", from: owner, to: owner + "/current")
        XCTAssertFalse(manager.read(withIQ: old, on: stream()))
        manager.beginAuthentication(on: wire)
        XCTAssertFalse(manager.read(withIQ: old, on: wire))
        manager.requestList(wire)
        let currentID = try XCTUnwrap(wire.elements.last?.attributeStringValue(forName: "id"))
        XCTAssertTrue(manager.read(withIQ: try deviceListResult(id: currentID, type: "result",
            from: owner, to: owner + "/current"), on: wire))
        manager.requestList(wire)
        let resetID = try XCTUnwrap(wire.elements.last?.attributeStringValue(forName: "id"))
        manager.clearSession()
        XCTAssertFalse(manager.read(withIQ: try deviceListResult(id: resetID, type: "result",
            from: owner, to: owner + "/current"), on: wire))
    }

    func testAuthenticationStartSuspendsAcceptedProofUntilActualResumeOrFreshSuccess() throws {
        let wire = stream()
        let manager = XMPPDeviceManager(withOwner: owner)
        manager.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
        let previous = try XCTUnwrap(manager.authenticatedSessionGeneration(on: wire))
        manager.beginAuthentication(on: wire)
        XCTAssertNil(manager.authenticatedDeviceID(on: wire), "isAuthenticated alone cannot reactivate pending proof")
        XCTAssertNil(manager.authenticatedSessionGeneration(on: wire))
        manager.recordAuthenticatedSession(on: wire, deviceID: nil, didResume: true)
        XCTAssertEqual(manager.authenticatedDeviceID(on: wire), "accepted-device")
        XCTAssertEqual(manager.authenticatedSessionGeneration(on: wire), previous)
    }

    func testAccountAccidentalReconnectResetSuspendsResumableProofButDefaultResetClearsIt() throws {
        let wire = stream()
        let account = account(stream: wire)
        account.devices.recordAuthenticatedSession(on: wire, deviceID: "accepted-device", didResume: false)
        let previous = try XCTUnwrap(account.devices.authenticatedSessionGeneration(on: wire))

        account.resetModules(preservingDeviceBindingForResume: true)

        XCTAssertNil(account.devices.authenticatedDeviceID(on: wire))
        account.devices.recordAuthenticatedSession(on: wire, deviceID: nil, didResume: true)
        XCTAssertEqual(account.devices.authenticatedDeviceID(on: wire), "accepted-device")
        XCTAssertEqual(account.devices.authenticatedSessionGeneration(on: wire), previous)
        account.resetModules()
        account.devices.recordAuthenticatedSession(on: wire, deviceID: nil, didResume: true)
        XCTAssertNil(account.devices.authenticatedDeviceID(on: wire))
    }

    private func deviceListResult(id: String, type: String, from: String, to: String) throws -> XMPPIQ {
        try XMPPIQ(xmlString: "<iq type='\(type)' id='\(id)' from='\(from)' to='\(to)'><query xmlns='https://xabber.com/protocol/devices#items'><device xmlns='https://xabber.com/protocol/devices' id='listed-device'><client>Xabber</client><expire>2000000000</expire><ip>127.0.0.1</ip><last-auth>1</last-auth><omemo-id>42</omemo-id></device></query></iq>")
    }

    private func registrationResult(id: String, from: String? = nil, type: String = "result") throws -> XMPPIQ {
        let sender = from.map { " from='\($0)'" } ?? ""
        return try XMPPIQ(xmlString: "<iq type='\(type)' id='\(id)'\(sender)><device xmlns='https://xabber.com/protocol/devices' id='registered-device'><secret>Zml4dHVyZS1zZWNyZXQ=</secret><validation-key>Zml4dHVyZS12YWxpZGF0aW9u</validation-key><expire>2000000000</expire></device></iq>")
    }
}
