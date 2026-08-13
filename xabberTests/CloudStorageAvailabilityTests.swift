import XCTest
import XMPPFramework
import RxSwift
@testable import xabber

final class CloudStorageAvailabilityTests: XCTestCase {
    private var owner: String!
    private let endpoint = URL(string: "https://gallery.example/api/")!
    private let premiumEndpoint = URL(string: "https://premium-gallery.example/api/")!
    private var tokenClient: CloudStorageAvailabilityTokenAPIClient!
    private var quotaClient: CloudStorageAvailabilityQuotaAPIClient!

    override func setUp() {
        super.setUp()
        owner = "cloud-availability-\(UUID().uuidString)@example.com"
        tokenClient = CloudStorageAvailabilityTokenAPIClient()
        quotaClient = CloudStorageAvailabilityQuotaAPIClient()
        XabberUploadManager.tokenAPIClient = tokenClient
        XabberUploadManager.quotaAPIClient = quotaClient
        XabberUploadManager.tokenExpiredTestingHandler = nil
        XabberUploadManager.networkPathMonitorFactory = { nil }
        XabberUploadManager.authorizationTimeoutInterval = 10
        XabberUploadManager.authorizationSuccessWillCommitTestingHandler = nil
        ServerDiscoManager.cloudDiscoveryTimeoutInterval = 6
        ServerDiscoManager.cloudDiscoveryWillRegisterQueryTestingHandler = nil
        ServerDiscoManager.cloudDiscoveryDidRegisterQueryTestingHandler = nil
        ServerDiscoManager.cloudDiscoveryDidConsumeTerminalTestingHandler = nil
        CloudStorageQuotaRefreshCoordinator.shared.resetTestingHooks()
        AccountManager.shared.users.removeAll()
        AccountGalleryConfiguration(owner: owner).clearPersistedState()
    }

    override func tearDown() {
        AccountManager.shared.users.removeAll()
        AccountGalleryConfiguration(owner: owner).clearPersistedState()
        XabberUploadManager.tokenAPIClient = AlamofireCloudStorageTokenAPIClient()
        XabberUploadManager.quotaAPIClient = AlamofireCloudStorageQuotaAPIClient()
        XabberUploadManager.tokenExpiredTestingHandler = nil
        XabberUploadManager.networkPathMonitorFactory = { AccountNWPathMonitor() }
        XabberUploadManager.authorizationTimeoutInterval = 10
        XabberUploadManager.authorizationSuccessWillCommitTestingHandler = nil
        ServerDiscoManager.cloudDiscoveryTimeoutInterval = 6
        ServerDiscoManager.cloudDiscoveryWillRegisterQueryTestingHandler = nil
        ServerDiscoManager.cloudDiscoveryDidRegisterQueryTestingHandler = nil
        ServerDiscoManager.cloudDiscoveryDidConsumeTerminalTestingHandler = nil
        CloudStorageQuotaRefreshCoordinator.shared.resetTestingHooks()
        quotaClient = nil
        tokenClient = nil
        owner = nil
        super.tearDown()
    }

    func testEndpointProvesCapabilityButTokenControlsOperationalReadiness() {
        let configuration = AccountGalleryConfiguration(owner: owner)
        let manager = XabberUploadManager(withOwner: owner)

        manager.resolveAuthoritativeDiscovery(endpoint: endpoint)

        XCTAssertEqual(manager.availabilityRelay.value, .authorizing(endpoint: endpoint))
        XCTAssertFalse(manager.isAvailable())
        XCTAssertTrue(SignInCloudStorageFeaturePresentationPolicy.resolve(manager.availabilityRelay.value).isCapabilitySupported)

        configuration.storeToken("scoped-token", galleryType: .basic, baseURL: endpoint)
        manager.noteTokenResolved(galleryType: .basic, endpoint: endpoint)

        XCTAssertEqual(manager.availabilityRelay.value, .ready(endpoint: endpoint))
        XCTAssertTrue(manager.isAvailable())
    }

    func testTokenResolvedSignalWithoutMatchingScopedTokenCannotPublishReady() {
        let manager = XabberUploadManager(withOwner: owner)
        manager.resolveAuthoritativeDiscovery(endpoint: endpoint)

        manager.noteTokenResolved(galleryType: .basic, endpoint: endpoint)

        XCTAssertEqual(manager.availabilityRelay.value, .authorizing(endpoint: endpoint))
        XCTAssertFalse(manager.isAvailable())
    }

    func testOnlyAuthoritativeDiscoveryWithoutEndpointIsUnsupported() {
        let manager = XabberUploadManager(withOwner: owner)

        manager.markAvailabilityRetryableFailure(stage: .discovery)
        XCTAssertNotEqual(manager.availabilityRelay.value, .unsupported)

        manager.resolveAuthoritativeDiscovery(endpoint: nil)

        XCTAssertEqual(manager.availabilityRelay.value, .unsupported)
    }

    func testRetryableAuthorizationFailurePreservesKnownEndpoint() {
        let manager = XabberUploadManager(withOwner: owner)
        manager.resolveAuthoritativeDiscovery(endpoint: endpoint)

        manager.markAvailabilityRetryableFailure(stage: .authorization)

        XCTAssertEqual(
            manager.availabilityRelay.value,
            .retryableFailure(stage: .authorization, endpoint: endpoint)
        )
        let onboardingState = SignInCloudStorageFeatureReducer.reduce(
            SignInCloudStorageFeatureReducer.initialState,
            availabilityState: manager.availabilityRelay.value
        )
        XCTAssertTrue(onboardingState.presentation.isCapabilitySupported)
        XCTAssertEqual(onboardingState.presentation.featureValue, true)
        XCTAssertEqual(onboardingState.presentation.displayFeatureValue, true)
        XCTAssertFalse(onboardingState.presentation.isPermanentFailure)
    }

    func testEndpointlessRetryableFailureRemainsNeutralAndNonPermanentInOnboarding() {
        let state = SignInCloudStorageFeatureReducer.reduce(
            SignInCloudStorageFeatureReducer.initialState,
            availabilityState: .retryableFailure(stage: .discovery, endpoint: nil)
        )

        XCTAssertNil(state.presentation.featureValue)
        XCTAssertNil(state.presentation.displayFeatureValue)
        XCTAssertFalse(state.presentation.isCapabilitySupported)
        XCTAssertFalse(state.presentation.isPermanentFailure)
        XCTAssertEqual(state.presentation.status, .retryableFailure)
        XCTAssertTrue(state.shouldResolveControls)
    }

    func testReadyCloudRemainsOperationalAfterQuotaNetworkAndServerFailures() {
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.storeBasicGalleryURL(endpoint.absoluteString)
        configuration.storeToken("scoped-token", galleryType: .basic, baseURL: endpoint)
        quotaClient.statsResponses = [
            .failure(statusCode: nil, error: URLError(.networkConnectionLost)),
            .response(statusCode: 500, value: ["status": 500])
        ]
        let manager = XabberUploadManager(withOwner: owner)

        for expectedRequestCount in 1...2 {
            var result: CloudStorageQuotaRefreshResult?
            manager.refreshQuota(reason: .manual) { result = $0 }

            XCTAssertEqual(result, .failure)
            XCTAssertEqual(quotaClient.statsRequestCount, expectedRequestCount)
            XCTAssertEqual(manager.availabilityRelay.value, .ready(endpoint: endpoint))
            XCTAssertTrue(manager.isAvailable())
            XCTAssertEqual(
                SignInCloudStorageFeaturePresentationPolicy
                    .resolve(manager.availabilityRelay.value)
                    .displayFeatureValue,
                true
            )
        }
    }

    func testQuotaUnauthorizedStillClearsTokenAndStartsReauthorization() {
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.storeBasicGalleryURL(endpoint.absoluteString)
        configuration.storeToken("scoped-token", galleryType: .basic, baseURL: endpoint)
        quotaClient.statsResponses = [
            .response(statusCode: 401, value: ["status": 401])
        ]
        let account = makeAccount()
        account.xmppStream.myJID = XMPPJID(string: "\(owner!)/ios")
        var result: CloudStorageQuotaRefreshResult?

        account.cloudStorage.refreshQuota(reason: .manual) { result = $0 }

        XCTAssertEqual(result, .unauthorized)
        XCTAssertEqual(tokenClient.codeRequestCount, 1)
        XCTAssertTrue(configuration.token(for: .basic, baseURL: endpoint).isEmpty)
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .authorizing(endpoint: endpoint)
        )
        XCTAssertFalse(account.cloudStorage.isAvailable())
    }

    func testStaleUnauthorizedResponseCannotClearRotatedToken() {
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.storeBasicGalleryURL(endpoint.absoluteString)
        configuration.storeToken("old-token", galleryType: .basic, baseURL: endpoint)
        let staleContext = CloudStorageGalleryRequestContext.make(
            owner: owner,
            galleryType: .basic,
            baseURL: endpoint,
            token: "old-token"
        )
        let account = makeAccount()
        account.xmppStream.myJID = XMPPJID(string: "\(owner!)/ios")
        configuration.storeToken("rotated-token", galleryType: .basic, baseURL: endpoint)
        account.cloudStorage.noteTokenResolved(galleryType: .basic, endpoint: endpoint)

        account.cloudStorage.handleUnauthorized(context: staleContext)

        XCTAssertEqual(
            configuration.token(for: .basic, baseURL: endpoint),
            "rotated-token"
        )
        XCTAssertEqual(tokenClient.codeRequestCount, 0)
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .ready(endpoint: endpoint)
        )
    }

    func testAuthorizationWithoutBoundFullJIDTransitionsToReplayableFailure() {
        let account = makeAccount()
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.storeBasicGalleryURL(endpoint.absoluteString)
        account.xmppStream.myJID = nil

        account.cloudStorage.requestAuthIfNeeded(galleryType: .basic, baseURL: endpoint)

        XCTAssertEqual(tokenClient.codeRequestCount, 0)
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .retryableFailure(stage: .authorization, endpoint: endpoint)
        )
        XCTAssertTrue(
            SignInCloudStorageFeaturePresentationPolicy
                .resolve(account.cloudStorage.availabilityRelay.value)
                .isCapabilitySupported
        )
    }

    func testQuotaIsPendingWhileDiscoveryOrAuthorizationIsUnresolved() {
        let manager = XabberUploadManager(withOwner: owner)
        var discoveryResult: CloudStorageQuotaRefreshResult?

        manager.refreshQuota { discoveryResult = $0 }

        XCTAssertEqual(discoveryResult, .pending)

        manager.resolveAuthoritativeDiscovery(endpoint: endpoint)
        var authorizationResult: CloudStorageQuotaRefreshResult?

        manager.refreshQuota { authorizationResult = $0 }

        XCTAssertEqual(authorizationResult, .pending)
    }

    func testQuotaResultMapsRetryableReadinessStagesWithoutReportingUnsupported() {
        let manager = XabberUploadManager(withOwner: owner)

        manager.markAvailabilityRetryableFailure(stage: .discovery)
        var discoveryResult: CloudStorageQuotaRefreshResult?
        manager.refreshQuota { discoveryResult = $0 }
        XCTAssertEqual(discoveryResult, .pending)

        manager.resolveAuthoritativeDiscovery(endpoint: endpoint)
        manager.markAvailabilityRetryableFailure(stage: .authorization)
        var authorizationResult: CloudStorageQuotaRefreshResult?
        manager.refreshQuota { authorizationResult = $0 }
        XCTAssertEqual(authorizationResult, .pending)

        manager.resolveAuthoritativeDiscovery(endpoint: endpoint)
        manager.markAvailabilityRetryableFailure(stage: .disconnected)
        XCTAssertEqual(
            manager.availabilityRelay.value,
            .retryableFailure(stage: .disconnected, endpoint: endpoint)
        )
        var disconnectedResult: CloudStorageQuotaRefreshResult?
        manager.refreshQuota { disconnectedResult = $0 }
        XCTAssertEqual(disconnectedResult, .pending)

        manager.markAvailabilityRetryableFailure(stage: .quota)
        var quotaResult: CloudStorageQuotaRefreshResult?
        manager.refreshQuota { quotaResult = $0 }
        XCTAssertEqual(quotaResult, .failure)
    }

    func testAvailabilityStateIsIsolatedPerAccount() {
        let otherOwner = "cloud-availability-other-\(UUID().uuidString)@example.com"
        defer { AccountGalleryConfiguration(owner: otherOwner).clearPersistedState() }
        let first = XabberUploadManager(withOwner: owner)
        let second = XabberUploadManager(withOwner: otherOwner)

        first.resolveAuthoritativeDiscovery(endpoint: endpoint)
        second.resolveAuthoritativeDiscovery(endpoint: nil)

        XCTAssertEqual(first.availabilityRelay.value, .authorizing(endpoint: endpoint))
        XCTAssertEqual(second.availabilityRelay.value, .unsupported)
    }

    func testAvailabilityPublisherSerializesConcurrentAndReentrantTransitions() {
        let firstTransitionEnteredPublisher = expectation(
            description: "first transition entered serialized publisher"
        )
        let firstTransitionMayContinue = DispatchSemaphore(value: 0)
        let firstPublishFinished = expectation(description: "first publish finished")
        let concurrentPublishQueued = expectation(description: "concurrent publish queued")
        let retryableState = CloudStorageAvailabilityState.retryableFailure(
            stage: .authorization,
            endpoint: endpoint
        )
        let publisher = CloudStorageAvailabilityPublisher(
            initialState: .discovering,
            willAccept: { state in
                guard state == .authorizing(endpoint: self.endpoint) else { return }
                firstTransitionEnteredPublisher.fulfill()
                _ = firstTransitionMayContinue.wait(timeout: .now() + 2)
            }
        )
        var observedStates: [CloudStorageAvailabilityState] = []
        let subscription = publisher.relay
            .skip(1)
            .subscribe(onNext: { state in
                observedStates.append(state)
                if state == retryableState {
                    publisher.publish(.ready(endpoint: self.endpoint))
                }
            })
        defer { subscription.dispose() }

        DispatchQueue.global(qos: .userInitiated).async {
            publisher.publish(.authorizing(endpoint: self.endpoint))
            firstPublishFinished.fulfill()
        }
        wait(for: [firstTransitionEnteredPublisher], timeout: 1)

        DispatchQueue.global(qos: .userInitiated).async {
            publisher.publish(retryableState)
            concurrentPublishQueued.fulfill()
        }
        wait(for: [concurrentPublishQueued], timeout: 1)
        firstTransitionMayContinue.signal()
        wait(for: [firstPublishFinished], timeout: 1)

        XCTAssertEqual(
            observedStates,
            [
                .authorizing(endpoint: endpoint),
                retryableState,
                .ready(endpoint: endpoint)
            ]
        )
        XCTAssertEqual(publisher.relay.value, .ready(endpoint: endpoint))
    }

    func testRepeatedAuthoritativeDiscoWithSameEndpointDoesNotBecomeUnsupported() throws {
        let account = makeAccount()
        let stream = CloudStorageAvailabilityCapturingStream()

        for _ in 0..<2 {
            account.disco.requestServerFeatures(stream)
            let queryID = try XCTUnwrap(stream.lastDiscoRequestID)

            XCTAssertTrue(
                account.disco.read(
                    withIQ: try makeGalleryDiscoIQ(id: queryID, endpoint: endpoint)
                )
            )
            XCTAssertEqual(
                account.cloudStorage.availabilityRelay.value,
                .authorizing(endpoint: endpoint)
            )
        }
    }

    func testCapsReceivedBecomesTerminalOnlyForTrackedAuthoritativeServerQuery() throws {
        let account = makeAccount()
        let manager = AccountManager.shared
        let originalNewAccountJid = manager.newAccountJid
        let originalObserver = manager.newAccountObservable.value
        defer {
            manager.newAccountJid = originalNewAccountJid
            manager.newAccountObservable.accept(originalObserver)
        }

        manager.newAccountJid = owner
        manager.newAccountObservable.accept(
            AccountManager.UserObserver(jid: owner, state: .auth)
        )

        let nonAuthoritativeQueryID = "contact-disco"
        account.disco.queryIds.insert(nonAuthoritativeQueryID)
        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeCapabilityDiscoIQ(id: nonAuthoritativeQueryID)
            )
        )

        XCTAssertEqual(
            manager.newAccountJid,
            owner,
            "A contact/component disco response must not consume the one terminal onboarding transition"
        )
        guard case .auth = manager.newAccountObservable.value.state else {
            return XCTFail("Non-authoritative disco must leave onboarding waiting for the server response")
        }

        let stream = CloudStorageAvailabilityCapturingStream()
        account.disco.requestServerFeatures(stream)
        let authoritativeQueryID = try XCTUnwrap(stream.lastDiscoRequestID)
        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeCapabilityDiscoIQ(id: authoritativeQueryID)
            )
        )

        guard case .capsReceived(let capabilities) = manager.newAccountObservable.value.state else {
            return XCTFail("Tracked authoritative server disco must complete capability onboarding")
        }
        XCTAssertTrue(capabilities.contains("mam"))
        XCTAssertEqual(manager.newAccountJid, "")
    }

    func testAuthoritativeDiscoErrorTerminatesOnboardingAsRetryableWithoutClaimingMAMUnsupported() throws {
        let account = makeAccount()
        let manager = AccountManager.shared
        let originalNewAccountJid = manager.newAccountJid
        let originalObserver = manager.newAccountObservable.value
        defer {
            manager.newAccountJid = originalNewAccountJid
            manager.newAccountObservable.accept(originalObserver)
        }
        manager.newAccountJid = owner
        manager.newAccountObservable.accept(
            AccountManager.UserObserver(jid: owner, state: .auth)
        )
        let stream = CloudStorageAvailabilityCapturingStream()
        account.disco.requestServerFeatures(stream)
        let queryID = try XCTUnwrap(stream.lastDiscoRequestID)

        XCTAssertTrue(
            account.disco.read(withIQ: try makeDiscoErrorIQ(id: queryID))
        )

        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .retryableFailure(stage: .discovery, endpoint: nil)
        )
        guard case .capsReceived(let capabilities) = manager.newAccountObservable.value.state else {
            return XCTFail("A terminal authoritative disco error must release onboarding")
        }
        XCTAssertEqual(capabilities, [ServerDiscoManager.retryableServerCapabilitiesMarker])
        XCTAssertEqual(
            SignInServerFeaturesControlsPolicy.resolve(
                serverCapabilitiesAreRetryable: true,
                isMessageArchiveAvailable: false,
                areOtherRequiredFeaturesAvailable: false,
                cloudStorageAvailabilityState: account.cloudStorage.availabilityRelay.value
            ),
            .temporarilyUnverified,
            "A transient server disco failure must not be rendered as permanent MAM unsupported"
        )
    }

    func testNonAuthoritativeGalleryDiscoCannotMutateCloudCapabilityOrStartAuthorization() throws {
        let account = makeAccount()
        let queryID = "component-gallery-disco"
        account.disco.queryIds.insert(queryID)

        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeGalleryDiscoIQ(id: queryID, endpoint: endpoint)
            )
        )

        XCTAssertNil(AccountGalleryConfiguration(owner: owner).basicGalleryURL)
        XCTAssertEqual(account.cloudStorage.availabilityRelay.value, .discovering)
        XCTAssertEqual(tokenClient.codeRequestCount, 0)
    }

    func testDisconnectBeforeCloudQueryRegistrationPreventsSendAndStaleResponse() throws {
        let account = makeAccount()
        let stream = CloudStorageAvailabilityCapturingStream()
        var reservedQueryID: String?
        ServerDiscoManager.cloudDiscoveryWillRegisterQueryTestingHandler = { disco, queryID in
            reservedQueryID = queryID
            disco.cancelCloudDiscoveryForDisconnect()
        }

        account.disco.requestServerFeatures(stream)

        let queryID = try XCTUnwrap(reservedQueryID)
        XCTAssertEqual(stream.discoRequestCount, 0)
        XCTAssertFalse(
            account.disco.read(withIQ: try makeCapabilityDiscoIQ(id: queryID)),
            "A response from a reservation invalidated before registration must be ignored"
        )
    }

    func testDisconnectAfterCloudQueryRegistrationPreventsSendAndStaleResponse() throws {
        let account = makeAccount()
        let stream = CloudStorageAvailabilityCapturingStream()
        var registeredQueryID: String?
        ServerDiscoManager.cloudDiscoveryDidRegisterQueryTestingHandler = { disco in
            registeredQueryID = disco.activeCloudDiscoveryQueryIDForTesting
            disco.cancelCloudDiscoveryForDisconnect()
        }

        account.disco.requestServerFeatures(stream)

        let queryID = try XCTUnwrap(registeredQueryID)
        XCTAssertEqual(stream.discoRequestCount, 0)
        XCTAssertFalse(
            account.disco.read(withIQ: try makeCapabilityDiscoIQ(id: queryID)),
            "A response invalidated after registration but before send must be ignored"
        )
    }

    func testDisconnectTerminalReleasesFirstAccountOnboardingExactlyOnce() throws {
        let account = makeAccount()
        let manager = AccountManager.shared
        let originalNewAccountJid = manager.newAccountJid
        let originalObserver = manager.newAccountObservable.value
        defer {
            manager.newAccountJid = originalNewAccountJid
            manager.newAccountObservable.accept(originalObserver)
        }
        manager.newAccountJid = owner
        manager.newAccountObservable.accept(
            AccountManager.UserObserver(jid: owner, state: .auth)
        )
        let stream = CloudStorageAvailabilityCapturingStream()
        account.disco.requestServerFeatures(stream)
        let queryID = try XCTUnwrap(stream.lastDiscoRequestID)
        var terminalClaims: [ServerDiscoManager.CloudDiscoveryTerminalKind] = []
        ServerDiscoManager.cloudDiscoveryDidConsumeTerminalTestingHandler = { terminalClaims.append($0) }

        account.disco.cancelCloudDiscoveryForDisconnect()
        account.disco.cancelCloudDiscoveryForDisconnect()

        guard case .capsReceived(let capabilities) = manager.newAccountObservable.value.state else {
            return XCTFail("Disconnect must release onboarding after consuming authoritative disco")
        }
        XCTAssertEqual(capabilities, [ServerDiscoManager.retryableServerCapabilitiesMarker])
        XCTAssertEqual(terminalClaims, [.disconnect])
        XCTAssertFalse(account.disco.read(withIQ: try makeCapabilityDiscoIQ(id: queryID)))
    }

    func testTimeoutAndResponseRaceConsumesAuthoritativeQueryExactlyOnce() throws {
        let account = makeAccount()
        let stream = CloudStorageAvailabilityCapturingStream()
        let claimsLock = NSLock()
        var terminalClaims: [ServerDiscoManager.CloudDiscoveryTerminalKind] = []
        let firstTerminal = expectation(description: "one authoritative terminal claimant")
        firstTerminal.assertForOverFulfill = true
        ServerDiscoManager.cloudDiscoveryDidConsumeTerminalTestingHandler = { kind in
            claimsLock.lock()
            terminalClaims.append(kind)
            let shouldFulfill = terminalClaims.count == 1
            claimsLock.unlock()
            if shouldFulfill {
                firstTerminal.fulfill()
            }
        }
        ServerDiscoManager.cloudDiscoveryTimeoutInterval = 0.01

        account.disco.requestServerFeatures(stream)
        let queryID = try XCTUnwrap(stream.lastDiscoRequestID)
        let response = try makeCapabilityDiscoIQ(id: queryID)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.01) {
            _ = account.disco.read(withIQ: response)
        }

        wait(for: [firstTerminal], timeout: 1)
        let raceSettled = expectation(description: "timeout and response attempts settled")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            raceSettled.fulfill()
        }
        wait(for: [raceSettled], timeout: 1)

        claimsLock.lock()
        let capturedClaims = terminalClaims
        claimsLock.unlock()
        XCTAssertEqual(capturedClaims.count, 1)
        guard let terminalClaim = capturedClaims.first else {
            return XCTFail("The authoritative query must have exactly one terminal claimant")
        }
        XCTAssertTrue(terminalClaim == .response || terminalClaim == .timeout)
        XCTAssertFalse(account.disco.read(withIQ: response), "The losing terminal path must leave no stale query")
    }

    func testAuthorizationIsSingleFlightForSameAccountGalleryAndEndpoint() {
        let account = makeAccount()
        AccountGalleryConfiguration(owner: owner).storeBasicGalleryURL(endpoint.absoluteString)

        account.cloudStorage.requestAuthIfNeeded(galleryType: .basic, baseURL: endpoint)
        account.cloudStorage.requestAuthIfNeeded(galleryType: .basic, baseURL: endpoint)

        XCTAssertEqual(tokenClient.codeRequestCount, 1)
        XCTAssertEqual(account.cloudStorage.availabilityRelay.value, .authorizing(endpoint: endpoint))
    }

    func testSelectedPremiumGalleryWithoutTokenReconcilesReadyBasicToSingleAuthorization() {
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.storeBasicGalleryURL(endpoint.absoluteString)
        configuration.storeToken("basic-scoped-token", galleryType: .basic, baseURL: endpoint)
        let account = makeAccount()

        XCTAssertEqual(account.cloudStorage.availabilityRelay.value, .ready(endpoint: endpoint))

        configuration.reconcilePremiumGalleryAvailability(
            isAvailable: true,
            storageURL: premiumEndpoint.absoluteString
        )
        waitForAccountQueue(account)

        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .authorizing(endpoint: premiumEndpoint)
        )
        XCTAssertEqual(
            tokenClient.codeRequestBaseURLs.filter { $0 == premiumEndpoint }.count,
            1
        )
        XCTAssertTrue(
            configuration.token(for: .premium, baseURL: premiumEndpoint).isEmpty
        )

        account.cloudStorage.requestAuthIfNeeded(
            galleryType: .premium,
            baseURL: premiumEndpoint
        )

        XCTAssertEqual(
            tokenClient.codeRequestBaseURLs.filter { $0 == premiumEndpoint }.count,
            1,
            "The selected Gallery authorization must remain single-flight"
        )
    }

    func testUnifiedHostedPremiumAuthorizationStoresTokenForDiscoveredEndpoint() throws {
        owner = "cloud-availability-\(UUID().uuidString)@\(CommonConfigManager.shared.config.domain)"
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.clearPersistedState()
        configuration.storeBasicGalleryURL(endpoint.absoluteString)
        configuration.reconcilePremiumGalleryAvailability(
            isAvailable: true,
            storageURL: premiumEndpoint.absoluteString
        )
        let account = makeAccount()
        account.xmppStream.myJID = XMPPJID(string: "\(owner!)/ios")

        account.cloudStorage.requestAuthIfNeeded(
            galleryType: .premium,
            baseURL: endpoint
        )
        tokenClient.completeCodeRequest(
            at: 0,
            with: .response(statusCode: 200, value: nil)
        )
        XCTAssertTrue(
            account.cloudStorage.read(
                withIQ: try makeGalleryAuthorizationIQ(
                    code: "unified-premium",
                    endpoint: endpoint
                )
            )
        )
        tokenClient.completeExchangeRequest(
            at: 0,
            with: .response(statusCode: 200, value: ["token": "unified-premium-token"])
        )

        XCTAssertEqual(configuration.currentGalleryType, .premium)
        XCTAssertEqual(configuration.currentGalleryURL, endpoint)
        XCTAssertEqual(
            configuration.token(for: .premium, baseURL: endpoint),
            "unified-premium-token"
        )
        XCTAssertEqual(account.cloudStorage.availabilityRelay.value, .ready(endpoint: endpoint))
    }

    func testPremiumSelectedBeforeAuthoritativeDiscoStartsPremiumAuthorizationAndRejectsStaleBasicSuccess() throws {
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.reconcilePremiumGalleryAvailability(
            isAvailable: true,
            storageURL: premiumEndpoint.absoluteString
        )
        let account = makeAccount()
        let stream = CloudStorageAvailabilityCapturingStream()
        var callbackError: Error?
        tokenClient.onCodeRequest = { requestNumber in
            guard requestNumber == 1 else { return }
            self.tokenClient.completeCodeRequest(
                at: 0,
                with: .response(statusCode: 200, value: nil)
            )
            do {
                let confirmation = try self.makeGalleryAuthorizationIQ(
                    code: "basic-stale-code",
                    endpoint: self.endpoint
                )
                XCTAssertTrue(account.cloudStorage.read(withIQ: confirmation))
            } catch {
                callbackError = error
            }
        }
        defer { tokenClient.onCodeRequest = nil }

        account.disco.requestServerFeatures(stream)
        let queryID = try XCTUnwrap(stream.lastDiscoRequestID)
        XCTAssertTrue(
            account.disco.read(
                withIQ: try makeGalleryDiscoIQ(id: queryID, endpoint: endpoint)
            )
        )
        XCTAssertNil(callbackError)
        XCTAssertEqual(tokenClient.exchangeRequestCount, 1)
        XCTAssertEqual(
            tokenClient.codeRequestBaseURLs.filter { $0 == premiumEndpoint }.count,
            1,
            "Authoritative Basic discovery must also authorize the selected Premium Gallery"
        )
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .authorizing(endpoint: premiumEndpoint)
        )

        tokenClient.completeExchangeRequest(
            at: 0,
            with: .response(statusCode: 200, value: ["token": "stale-basic-token"])
        )

        XCTAssertTrue(configuration.token(for: .basic, baseURL: endpoint).isEmpty)
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .authorizing(endpoint: premiumEndpoint)
        )

        account.cloudStorage.requestAuthIfNeeded(galleryType: .basic, baseURL: endpoint)

        XCTAssertEqual(
            tokenClient.codeRequestBaseURLs.filter { $0 == premiumEndpoint }.count,
            1
        )
        XCTAssertEqual(
            tokenClient.codeRequestBaseURLs.filter { $0 == endpoint }.count,
            1,
            "A non-selected Basic retry must not supersede selected Premium authorization"
        )
    }

    func testAuthorizationNetworkTimeoutIsRetryableNotUnsupported() {
        let account = makeAccount()
        AccountGalleryConfiguration(owner: owner).storeBasicGalleryURL(endpoint.absoluteString)
        waitForAccountQueue(account)

        account.cloudStorage.requestAuthIfNeeded(galleryType: .basic, baseURL: endpoint)
        tokenClient.completeCodeRequest(
            at: 0,
            with: .failure(statusCode: nil, error: URLError(.timedOut))
        )

        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .retryableFailure(stage: .authorization, endpoint: endpoint)
        )
        XCTAssertNotEqual(account.cloudStorage.availabilityRelay.value, .unsupported)
    }

    func testDiscoveryTimeoutIsRetryableAndAllowsOneLaterRequest() {
        let account = makeAccount()
        let stream = CloudStorageAvailabilityCapturingStream()
        ServerDiscoManager.cloudDiscoveryTimeoutInterval = 0.02

        account.cloudStorage.resumeAvailabilityWorkIfNeeded(stream: stream, disco: account.disco)
        account.cloudStorage.resumeAvailabilityWorkIfNeeded(stream: stream, disco: account.disco)

        XCTAssertEqual(stream.discoRequestCount, 1)

        let timedOut = expectation(description: "logical discovery timeout")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 1)

        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .retryableFailure(stage: .discovery, endpoint: nil)
        )

        ServerDiscoManager.cloudDiscoveryTimeoutInterval = 6
        account.cloudStorage.resumeAvailabilityWorkIfNeeded(stream: stream, disco: account.disco)

        XCTAssertEqual(stream.discoRequestCount, 2)
    }

    func testAuthoritativeDiscoveryTimeoutReleasesOnboardingThroughRetryableTerminalState() {
        let account = makeAccount()
        let stream = CloudStorageAvailabilityCapturingStream()
        let manager = AccountManager.shared
        let originalNewAccountJid = manager.newAccountJid
        let originalObserver = manager.newAccountObservable.value
        defer {
            manager.newAccountJid = originalNewAccountJid
            manager.newAccountObservable.accept(originalObserver)
        }
        manager.newAccountJid = owner
        manager.newAccountObservable.accept(
            AccountManager.UserObserver(jid: owner, state: .auth)
        )
        ServerDiscoManager.cloudDiscoveryTimeoutInterval = 0.02

        account.cloudStorage.resumeAvailabilityWorkIfNeeded(stream: stream, disco: account.disco)

        let timedOut = expectation(description: "authoritative discovery timeout releases onboarding")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 1)

        guard case .capsReceived(let capabilities) = manager.newAccountObservable.value.state else {
            return XCTFail("A terminal authoritative disco timeout must release onboarding")
        }
        XCTAssertEqual(capabilities, [ServerDiscoManager.retryableServerCapabilitiesMarker])
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .retryableFailure(stage: .discovery, endpoint: nil)
        )
    }

    func testStaleAuthorizationCallbackCannotOverwriteNewAttempt() {
        let account = makeAccount()
        AccountGalleryConfiguration(owner: owner).storeBasicGalleryURL(endpoint.absoluteString)
        XabberUploadManager.authorizationTimeoutInterval = 0.02

        account.cloudStorage.requestAuthIfNeeded(galleryType: .basic, baseURL: endpoint)

        let timedOut = expectation(description: "logical authorization timeout")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 1)
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .retryableFailure(stage: .authorization, endpoint: endpoint)
        )

        XabberUploadManager.authorizationTimeoutInterval = 10
        account.cloudStorage.requestAuthIfNeeded(galleryType: .basic, baseURL: endpoint)
        XCTAssertEqual(tokenClient.codeRequestCount, 2)

        tokenClient.completeCodeRequest(at: 0, with: .failure(statusCode: nil, error: URLError(.timedOut)))

        XCTAssertEqual(account.cloudStorage.availabilityRelay.value, .authorizing(endpoint: endpoint))
    }

    func testStaleTokenSuccessCannotCommitAfterDisconnectAndNewSameIdentityAttempt() throws {
        let account = makeAccount()
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.storeBasicGalleryURL(endpoint.absoluteString)

        account.cloudStorage.requestAuthIfNeeded(galleryType: .basic, baseURL: endpoint)
        tokenClient.completeCodeRequest(
            at: 0,
            with: .response(statusCode: 200, value: nil)
        )
        XCTAssertTrue(
            account.cloudStorage.read(
                withIQ: try makeGalleryAuthorizationIQ(code: "stale-code")
            )
        )
        XCTAssertEqual(tokenClient.exchangeRequestCount, 1)

        let staleSuccessReachedCommit = expectation(
            description: "stale success reached atomic generation commit"
        )
        let allowStaleSuccessToCommit = DispatchSemaphore(value: 0)
        let staleSuccessFinished = expectation(description: "stale success callback finished")
        XabberUploadManager.authorizationSuccessWillCommitTestingHandler = {
            staleSuccessReachedCommit.fulfill()
            _ = allowStaleSuccessToCommit.wait(timeout: .now() + 2)
        }
        defer {
            allowStaleSuccessToCommit.signal()
            XabberUploadManager.authorizationSuccessWillCommitTestingHandler = nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            self.tokenClient.completeExchangeRequest(
                at: 0,
                with: .response(statusCode: 200, value: ["token": "stale-token"])
            )
            staleSuccessFinished.fulfill()
        }
        wait(for: [staleSuccessReachedCommit], timeout: 1)

        account.cloudStorage.markAvailabilityRetryableFailure(stage: .disconnected)
        account.cloudStorage.requestAuthIfNeeded(galleryType: .basic, baseURL: endpoint)
        XCTAssertEqual(tokenClient.codeRequestCount, 2)
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .authorizing(endpoint: endpoint)
        )

        allowStaleSuccessToCommit.signal()
        wait(for: [staleSuccessFinished], timeout: 1)
        XabberUploadManager.authorizationSuccessWillCommitTestingHandler = nil

        XCTAssertTrue(configuration.token(for: .basic, baseURL: endpoint).isEmpty)
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .authorizing(endpoint: endpoint)
        )

        tokenClient.completeCodeRequest(
            at: 1,
            with: .response(statusCode: 200, value: nil)
        )
        XCTAssertTrue(
            account.cloudStorage.read(
                withIQ: try makeGalleryAuthorizationIQ(code: "fresh-code")
            )
        )
        XCTAssertEqual(tokenClient.exchangeRequestCount, 2)
        XCTAssertTrue(configuration.token(for: .basic, baseURL: endpoint).isEmpty)
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .authorizing(endpoint: endpoint)
        )
    }

    func testOnboardingReducerReplaysNeutralRetryIntoLateReadyState() {
        var state = SignInCloudStorageFeatureReducer.initialState

        state = SignInCloudStorageFeatureReducer.reduce(
            state,
            availabilityState: .retryableFailure(stage: .discovery, endpoint: nil)
        )
        XCTAssertNil(state.presentation.featureValue)
        XCTAssertNil(state.presentation.displayFeatureValue)
        XCTAssertFalse(state.presentation.isPermanentFailure)
        XCTAssertTrue(state.shouldResolveControls)
        XCTAssertEqual(
            SignInServerFeaturesControlsPolicy.resolve(
                isMessageArchiveAvailable: true,
                areOtherRequiredFeaturesAvailable: true,
                cloudStorageAvailabilityState: state.availabilityState
            ),
            .fullySupported
        )

        state = SignInCloudStorageFeatureReducer.reduce(
            state,
            availabilityState: .ready(endpoint: endpoint)
        )
        XCTAssertEqual(state.presentation.featureValue, true)
        XCTAssertEqual(state.presentation.status, .supported)
        XCTAssertTrue(state.shouldResolveControls)
        XCTAssertEqual(
            SignInServerFeaturesControlsPolicy.resolve(
                isMessageArchiveAvailable: true,
                areOtherRequiredFeaturesAvailable: true,
                cloudStorageFeatureValue: state.presentation.featureValue
            ),
            .fullySupported
        )

        state = SignInCloudStorageFeatureReducer.reduce(
            state,
            availabilityState: .unsupported
        )
        state = SignInCloudStorageFeatureReducer.reduce(
            state,
            availabilityState: .ready(endpoint: endpoint)
        )
        XCTAssertEqual(state.presentation.featureValue, true)
        XCTAssertFalse(state.presentation.isPermanentFailure)
        XCTAssertEqual(state.presentation.status, .supported)
        XCTAssertEqual(
            SignInServerFeaturesControlsPolicy.resolve(
                isMessageArchiveAvailable: true,
                areOtherRequiredFeaturesAvailable: true,
                cloudStorageFeatureValue: state.presentation.featureValue
            ),
            .fullySupported
        )
    }

    func testEndpointlessRetryableFailureShowsTransientStateWithoutBlockingOnboarding() {
        let state = SignInCloudStorageFeatureReducer.reduce(
            SignInCloudStorageFeatureReducer.initialState,
            availabilityState: .retryableFailure(stage: .discovery, endpoint: nil)
        )

        XCTAssertEqual(state.presentation.status, .retryableFailure)
        XCTAssertFalse(state.presentation.isPermanentFailure)
        XCTAssertTrue(
            state.shouldResolveControls,
            "A completed transient failure must not leave File upload and the onboarding controls spinning forever"
        )
        XCTAssertEqual(
            SignInServerFeaturesControlsPolicy.resolve(
                isMessageArchiveAvailable: true,
                areOtherRequiredFeaturesAvailable: true,
                cloudStorageAvailabilityState: state.availabilityState
            ),
            .fullySupported,
            "A retryable Cloud check must allow entry without the permanent unsupported warning"
        )
    }

    func testServerFeaturesRevealPolicyReachesFileUploadWithinOneSecond() {
        XCTAssertLessThanOrEqual(
            SignInServerFeaturesRevealPolicy.totalDelayUntilFeature(at: 6),
            1.0
        )
        XCTAssertLessThanOrEqual(
            SignInServerFeaturesRevealPolicy.featureCadence,
            0.14
        )
    }

    func testServerFeaturesRenderGateDefersEarlyModelCallbacks() {
        XCTAssertEqual(
            SignInServerFeaturesRenderGatePolicy.action(
                isPresentationActive: false,
                isTableAttachedToWindow: false
            ),
            .deferFullReload
        )
        XCTAssertEqual(
            SignInServerFeaturesRenderGatePolicy.action(
                isPresentationActive: true,
                isTableAttachedToWindow: false
            ),
            .deferFullReload
        )
    }

    func testServerFeaturesRenderGateUsesFullReloadWhenPresentationIsActive() {
        XCTAssertEqual(
            SignInServerFeaturesRenderGatePolicy.action(
                isPresentationActive: true,
                isTableAttachedToWindow: true
            ),
            .commitFullReload
        )
    }

    func testAuthorizingEndpointResolvesOnboardingControlsBeforeTokenIsReady() {
        let presentation = SignInCloudStorageFeaturePresentationPolicy.resolve(
            .authorizing(endpoint: endpoint)
        )

        XCTAssertEqual(presentation.featureValue, true)
        XCTAssertEqual(presentation.status, .supported)
        XCTAssertEqual(
            SignInServerFeaturesControlsPolicy.resolve(
                isMessageArchiveAvailable: true,
                areOtherRequiredFeaturesAvailable: true,
                cloudStorageFeatureValue: presentation.featureValue
            ),
            .fullySupported
        )
    }

    func testForegroundQuotaRefreshTriggersAvailabilityRecoveryBeforeQuota() {
        var events: [String] = []
        CloudStorageQuotaRefreshCoordinator.shared.availabilityResumeOwnerHandler = { owner in
            XCTAssertEqual(owner, self.owner)
            events.append("resume")
        }
        CloudStorageQuotaRefreshCoordinator.shared.refreshOwnerHandler = { owner, reason, force, completion in
            XCTAssertEqual(owner, self.owner)
            XCTAssertEqual(reason, .foreground)
            XCTAssertFalse(force)
            events.append("quota")
            completion?(.pending)
        }
        var result: CloudStorageQuotaRefreshResult?

        CloudStorageQuotaRefreshCoordinator.shared.refresh(
            owner: owner,
            reason: .foreground,
            completion: { result = $0 }
        )

        XCTAssertEqual(events, ["resume", "quota"])
        XCTAssertEqual(result, .pending)
    }

    func testAttachmentEntryAlwaysPresentsAndOnlyTemporaryAvailabilityResumes() {
        XCTAssertEqual(
            ChatAttachmentPickerEntryPlan.make(
                isTelegramAttachmentPickerEnabled: true,
                availabilityState: .discovering
            ),
            ChatAttachmentPickerEntryPlan(
                presentsPicker: true,
                resumesAvailability: true
            )
        )
        XCTAssertEqual(
            ChatAttachmentPickerEntryPlan.make(
                isTelegramAttachmentPickerEnabled: true,
                availabilityState: .retryableFailure(stage: .authorization, endpoint: endpoint)
            ),
            ChatAttachmentPickerEntryPlan(
                presentsPicker: true,
                resumesAvailability: true
            )
        )
        XCTAssertEqual(
            ChatAttachmentPickerEntryPlan.make(
                isTelegramAttachmentPickerEnabled: true,
                availabilityState: .unsupported
            ),
            ChatAttachmentPickerEntryPlan(
                presentsPicker: true,
                resumesAvailability: false
            )
        )
        XCTAssertEqual(
            ChatAttachmentPickerEntryPlan.make(
                isTelegramAttachmentPickerEnabled: true,
                availabilityState: .ready(endpoint: endpoint)
            ),
            ChatAttachmentPickerEntryPlan(
                presentsPicker: true,
                resumesAvailability: false
            )
        )
    }

    func testExplicitAttachmentRetryRestartsAuthorizationSingleFlight() {
        let account = makeAccount()
        let configuration = AccountGalleryConfiguration(owner: owner)
        configuration.storeBasicGalleryURL(endpoint.absoluteString)
        account.xmppStream.myJID = XMPPJID(string: "\(owner!)/ios")
        account.cloudStorage.markAvailabilityRetryableFailure(stage: .authorization)
        let provider = AccountChatAttachmentCloudStorageAvailabilityProvider()

        XCTAssertFalse(provider.isCloudStorageAvailable(owner: owner))
        XCTAssertFalse(provider.isCloudStorageAvailable(owner: owner))

        XCTAssertEqual(tokenClient.codeRequestCount, 1)
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .authorizing(endpoint: endpoint)
        )
    }

    private func makeAccount() -> Account {
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "CloudStorageAvailabilityTests.\(UUID().uuidString)")
        )
        account.configureStream()
        AccountManager.shared.users.append(account)
        return account
    }

    private func waitForAccountQueue(_ account: Account) {
        let drained = expectation(description: "account queue drained")
        account.action { _, _ in drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    private func makeGalleryDiscoIQ(id: String, endpoint: URL) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type="result" id="\(id)" from="example.com">
          <query xmlns="http://jabber.org/protocol/disco#info">
            <x xmlns="jabber:x:data" type="result">
              <field var="FORM_TYPE"><value>urn:xabber:http:url</value></field>
              <field var="urn:xabber:http:url:mediagallery"><value>\(endpoint.absoluteString)</value></field>
            </x>
          </query>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func makeCapabilityDiscoIQ(id: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type="result" id="\(id)" from="example.com">
          <query xmlns="http://jabber.org/protocol/disco#info">
            <feature var="urn:xmpp:mam:2" />
          </query>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func makeDiscoErrorIQ(id: String) throws -> XMPPIQ {
        let document = try DDXMLDocument(xmlString: """
        <iq type="error" id="\(id)" from="example.com">
          <error type="wait">
            <remote-server-timeout xmlns="urn:ietf:params:xml:ns:xmpp-stanzas" />
          </error>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

    private func makeGalleryAuthorizationIQ(
        code: String,
        endpoint: URL? = nil
    ) throws -> XMPPIQ {
        let authorizationURL = (endpoint ?? self.endpoint)
            .appendingPathComponent("authorize")
            .absoluteString
        let document = try DDXMLDocument(xmlString: """
        <iq type="get" id="gallery-auth-\(code)" from="example.com">
          <confirm xmlns="http://jabber.org/protocol/http-auth"
                   id="\(code)"
                   method="GET"
                   url="\(authorizationURL)" />
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }
}

final class FirstAccountSignInLifecycleTests: XCTestCase {
    func testOwnedIncompleteAccountIsRemovedWhenSignInDisappears() {
        XCTAssertTrue(
            SignInTemporaryAccountCleanupPolicy.shouldDelete(
                temporaryAccountJid: "pending@example.com",
                didTransferAccountOwnership: false,
                cleanupAlreadyPerformed: false
            )
        )
    }

    func testTypedAccountWithoutCreatedAttemptIsNeverRemoved() {
        XCTAssertFalse(
            SignInTemporaryAccountCleanupPolicy.shouldDelete(
                temporaryAccountJid: nil,
                didTransferAccountOwnership: false,
                cleanupAlreadyPerformed: false
            )
        )
    }

    func testSuccessfulCapabilityHandoffRetainsConnectedAccount() {
        XCTAssertFalse(
            SignInTemporaryAccountCleanupPolicy.shouldDelete(
                temporaryAccountJid: "connected@example.com",
                didTransferAccountOwnership: true,
                cleanupAlreadyPerformed: false
            )
        )
    }

    func testIntentionalPolicyViolationHandoffRetainsConnectedAccount() {
        XCTAssertFalse(
            SignInTemporaryAccountCleanupPolicy.shouldDelete(
                temporaryAccountJid: "policy-route@example.com",
                didTransferAccountOwnership: true,
                cleanupAlreadyPerformed: false
            )
        )
    }

    func testEmptyAccountIdentifierNeverStartsDestructiveCleanup() {
        XCTAssertFalse(
            SignInTemporaryAccountCleanupPolicy.shouldDelete(
                temporaryAccountJid: "",
                didTransferAccountOwnership: false,
                cleanupAlreadyPerformed: false
            )
        )
        XCTAssertFalse(
            SignInTemporaryAccountCleanupPolicy.shouldDelete(
                temporaryAccountJid: "   ",
                didTransferAccountOwnership: false,
                cleanupAlreadyPerformed: false
            )
        )
    }

    func testCompletedCleanupIsNotRepeatedOnLaterDisappearance() {
        XCTAssertFalse(
            SignInTemporaryAccountCleanupPolicy.shouldDelete(
                temporaryAccountJid: "removed@example.com",
                didTransferAccountOwnership: false,
                cleanupAlreadyPerformed: true
            )
        )
    }

    func testAttemptGenerationRejectsCancelledAndDifferentAccountCallbacks() {
        XCTAssertTrue(
            SignInAttemptCallbackPolicy.shouldAccept(
                callbackGeneration: 7,
                activeGeneration: 7,
                callbackJid: "active@example.com",
                temporaryAccountJid: "active@example.com"
            )
        )
        XCTAssertFalse(
            SignInAttemptCallbackPolicy.shouldAccept(
                callbackGeneration: 6,
                activeGeneration: 7,
                callbackJid: "active@example.com",
                temporaryAccountJid: "active@example.com"
            )
        )
        XCTAssertFalse(
            SignInAttemptCallbackPolicy.shouldAccept(
                callbackGeneration: 7,
                activeGeneration: 7,
                callbackJid: "stale@example.com",
                temporaryAccountJid: "active@example.com"
            )
        )
    }

    func testDuplicateCreateIsNoOpBeforeSignInOrCredentialMutation() {
        let jid = "duplicate-\(UUID().uuidString)@example.com"
        let manager = AccountManager()
        let existingAccount = Account(
            jid: jid,
            queue: DispatchQueue(label: "FirstAccountSignInLifecycleTests.duplicate")
        )
        manager.users = [existingAccount]
        manager.newAccountJid = "unchanged@example.com"
        manager.newAccountObservable.accept(
            AccountManager.UserObserver(jid: "unchanged@example.com", state: .auth)
        )
        CredentialsManager.shared.setItem(for: jid, token: "existing-token")

        let result = manager.create(
            jid: jid,
            password: "replacement-password",
            nickname: nil,
            isFromRegister: false
        )

        XCTAssertEqual(result, .alreadyExists)
        XCTAssertEqual(manager.newAccountJid, "unchanged@example.com")
        guard case .auth = manager.newAccountObservable.value.state else {
            return XCTFail("Duplicate create must not emit a new sign-in state")
        }
        XCTAssertEqual(CredentialsManager.shared.getItem(for: jid).creditionalString, "existing-token")
        XCTAssertEqual(manager.users.filter { $0.jid == jid }.count, 1)
    }

    func testSubscriptionRemovalIdentitySkipsEmptyAndFallsBackToJid() {
        let namespace = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

        XCTAssertEqual(
            SubscribtionsManager.removalIdentity(for: "", namespace: namespace),
            .skip
        )
        XCTAssertEqual(
            SubscribtionsManager.removalIdentity(
                for: "owner@example.com",
                namespace: "invalid-namespace"
            ),
            .jidOnly
        )
        guard case .jidAndAccountUUID(let accountUUID) = SubscribtionsManager.removalIdentity(
            for: "owner@example.com",
            namespace: namespace
        ) else {
            return XCTFail("Valid owner and namespace must include the scoped account UUID")
        }
        XCTAssertNotNil(UUID(uuidString: accountUUID))
    }

    func testSubscriptionRemovalWithEmptyOwnerReturnsBeforeRealmOrUUIDWork() {
        SubscribtionsManager.shared.remove(for: "", commitTransaction: false)
    }
}

private final class CloudStorageAvailabilityQuotaAPIClient: CloudStorageQuotaAPIClient {
    var statsResponses: [CloudStorageQuotaAPIResponse] = []
    private(set) var statsRequestCount = 0

    func getStats(
        baseURL: URL,
        token: String,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        statsRequestCount += 1
        let response = statsResponses.isEmpty
            ? CloudStorageQuotaAPIResponse.failure(statusCode: nil, error: nil)
            : statsResponses.removeFirst()
        completion(response)
    }

    func requestSlot(
        baseURL: URL,
        token: String,
        request: CloudStorageUploadSlotRequest,
        traceID: String,
        timeoutInterval: TimeInterval,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func uploadFile(
        baseURL: URL,
        token: String,
        data: Data,
        filename: String,
        fileMimeType: String,
        galleryMediaType: String,
        metadata: [String: String]?,
        context: String,
        traceID: String,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func deleteMedia(
        baseURL: URL,
        token: String,
        fileID: Int,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func deleteAvatar(
        baseURL: URL,
        token: String,
        fileID: Int,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func deleteGallery(
        baseURL: URL,
        token: String,
        jid: String,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func getFiles(
        baseURL: URL,
        token: String,
        type: MimeIconTypes,
        page: Int,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func getAvatars(
        baseURL: URL,
        token: String,
        page: Int,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func getFilesToDelete(
        baseURL: URL,
        token: String,
        percent: Int,
        page: Int,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func deleteMediaFor(
        baseURL: URL,
        token: String,
        percent: Int,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        completion(.failure(statusCode: nil, error: nil))
    }

    func deleteMediaForAll(
        baseURL: URL,
        token: String,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        completion(.failure(statusCode: nil, error: nil))
    }
}

private final class CloudStorageAvailabilityTokenAPIClient: CloudStorageTokenAPIClient {
    private var pendingCodeRequests: [(CloudStorageQuotaAPIResponse) -> Void] = []
    private var pendingExchangeRequests: [(CloudStorageQuotaAPIResponse) -> Void] = []
    private(set) var codeRequestCount = 0
    private(set) var exchangeRequestCount = 0
    private(set) var codeRequestBaseURLs: [URL] = []
    var onCodeRequest: ((Int) -> Void)?

    func requestCode(
        baseURL: URL,
        fullJID: String,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        codeRequestCount += 1
        codeRequestBaseURLs.append(baseURL)
        pendingCodeRequests.append(completion)
        onCodeRequest?(codeRequestCount)
    }

    func exchangeCode(
        baseURL: URL,
        owner: String,
        code: String,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        exchangeRequestCount += 1
        pendingExchangeRequests.append(completion)
    }

    func completeCodeRequest(at index: Int, with response: CloudStorageQuotaAPIResponse) {
        pendingCodeRequests[index](response)
    }

    func completeExchangeRequest(at index: Int, with response: CloudStorageQuotaAPIResponse) {
        pendingExchangeRequests[index](response)
    }
}

private final class CloudStorageAvailabilityCapturingStream: XMPPStream {
    private(set) var discoRequestCount = 0
    private(set) var lastDiscoRequestID: String?

    override func send(_ element: DDXMLElement) {
        if element.element(forName: "query")?.xmlns() == "http://jabber.org/protocol/disco#info" {
            discoRequestCount += 1
            lastDiscoRequestID = element.attributeStringValue(forName: "id")
        }
    }
}
