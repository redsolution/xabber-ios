import XCTest
import XMPPFramework
@testable import xabber

final class ChatAttachmentPickerEntryPointTests: XCTestCase {
    private var previousTelegramAttachmentPickerFlag: Bool?

    override func setUp() {
        super.setUp()
        previousTelegramAttachmentPickerFlag = CommonConfigManager.shared.config.use_telegram_attachment_picker
    }

    override func tearDown() {
        CommonConfigManager.shared.config.use_telegram_attachment_picker = previousTelegramAttachmentPickerFlag
        super.tearDown()
    }

    func testFlagOffAndCloudStorageAvailableSelectsLegacyPicker() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: false,
            isCloudStorageAvailable: true
        )

        XCTAssertEqual(route, .legacyImagePicker)
    }

    func testFlagOnAndCloudStorageAvailableSelectsTelegramAttachmentFlow() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: true,
            isCloudStorageAvailable: true
        )

        XCTAssertEqual(route, .telegramAttachmentFlow)
    }

    func testCloudStorageUnavailableBlocksLegacyRoute() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: false,
            isCloudStorageAvailable: false
        )

        XCTAssertEqual(route, .blocked(.cloudStorageUnavailable))
    }

    func testCloudStorageUnavailableBlocksTelegramAttachmentRoute() {
        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: true,
            isCloudStorageAvailable: false
        )

        XCTAssertEqual(route, .blocked(.cloudStorageUnavailable))
    }

    func testDiscoveryStartsEvenWhenLegacyHTTPUploadCapabilityIsCached() {
        let owner = "discovery-\(UUID().uuidString)@example.com"
        SettingManager.shared.saveItem(
            for: owner,
            scope: .httpUploader,
            key: "node",
            value: "upload.example.com"
        )
        defer {
            SettingManager.shared.removeItem(for: owner, scope: .httpUploader, key: "node")
            AccountGalleryConfiguration(owner: owner).clearPersistedState()
        }
        let stream = AttachmentDiscoveryCapturingXMPPStream()
        stream.myJID = XMPPJID(string: "\(owner)/ios")
        let disco = ServerDiscoManager(withOwner: owner)

        disco.configure(stream)

        XCTAssertEqual(disco.cloudStorageDiscoveryState, .discovering)
        let infoTargets = stream.sentElements.compactMap { element -> String? in
            guard element.element(forName: "query")?.xmlns() == "http://jabber.org/protocol/disco#info" else {
                return nil
            }
            return element.attributeStringValue(forName: "to")
        }
        XCTAssertTrue(infoTargets.contains("example.com"))
        XCTAssertTrue(infoTargets.contains(stream.myJID?.bare ?? owner))
    }

    func testDiscoveryBecomesAvailableAsSoonAsGalleryURLArrives() throws {
        let owner = "discovery-\(UUID().uuidString)@example.com"
        defer { AccountGalleryConfiguration(owner: owner).clearPersistedState() }
        let stream = AttachmentDiscoveryCapturingXMPPStream()
        stream.myJID = XMPPJID(string: "\(owner)/ios")
        let disco = ServerDiscoManager(withOwner: owner)
        disco.refreshCloudStorageDiscovery(stream)
        let request = try XCTUnwrap(stream.sentElements.first)
        let requestID = try XCTUnwrap(request.attributeStringValue(forName: "id"))

        XCTAssertTrue(disco.read(withIQ: try makeDiscoResult(
            id: requestID,
            from: request.attributeStringValue(forName: "to") ?? "example.com",
            galleryURL: "https://gallery.example.com/api/v1/"
        )))

        XCTAssertEqual(disco.cloudStorageDiscoveryState, .available)
        XCTAssertEqual(
            AccountGalleryConfiguration(owner: owner).basicGalleryURL?.absoluteString,
            "https://gallery.example.com/api/"
        )
    }

    func testDiscoveryCompletionWaitsForGalleryCapabilityResolution() throws {
        let owner = "readiness-\(UUID().uuidString)@example.com"
        defer { AccountGalleryConfiguration(owner: owner).clearPersistedState() }
        let stream = AttachmentDiscoveryCapturingXMPPStream()
        stream.myJID = XMPPJID(string: "\(owner)/ios")
        let disco = ServerDiscoManager(withOwner: owner)
        disco.cloudStorageDiscoveryTimeout = 0.01
        var resolvedState: CloudStorageDiscoveryState?
        let resolved = expectation(description: "cloud discovery resolved")

        disco.refreshCloudStorageDiscovery(stream) { state in
            resolvedState = state
            resolved.fulfill()
        }

        XCTAssertNil(resolvedState)
        let requests = stream.sentElements.filter {
            $0.element(forName: "query")?.xmlns() == "http://jabber.org/protocol/disco#info"
        }
        XCTAssertEqual(requests.count, 2)

        for request in requests {
            XCTAssertTrue(disco.read(withIQ: try makeDiscoResult(
                id: try XCTUnwrap(request.attributeStringValue(forName: "id")),
                from: request.attributeStringValue(forName: "to") ?? "example.com",
                galleryURL: nil
            )))
        }

        XCTAssertNil(resolvedState)
        XCTAssertEqual(disco.cloudStorageDiscoveryState, .discovering)
        wait(for: [resolved], timeout: 1)
        XCTAssertEqual(resolvedState, .unavailable)
    }

    func testDiscoveryWaitsForDiscoItemBeforeDeclaringGalleryUnavailable() throws {
        let owner = "item-readiness-\(UUID().uuidString)@example.com"
        defer { AccountGalleryConfiguration(owner: owner).clearPersistedState() }
        let stream = AttachmentDiscoveryCapturingXMPPStream()
        stream.myJID = XMPPJID(string: "\(owner)/ios")
        let disco = ServerDiscoManager(withOwner: owner)
        var resolvedState: CloudStorageDiscoveryState?

        disco.configure(stream) { state in
            resolvedState = state
        }

        let initialInfoRequests = stream.sentElements.filter {
            $0.element(forName: "query")?.xmlns() == "http://jabber.org/protocol/disco#info"
        }
        for request in initialInfoRequests {
            XCTAssertTrue(disco.read(withIQ: try makeDiscoResult(
                id: try XCTUnwrap(request.attributeStringValue(forName: "id")),
                from: request.attributeStringValue(forName: "to") ?? "example.com",
                galleryURL: nil
            )))
        }
        XCTAssertNil(resolvedState)
        XCTAssertEqual(disco.cloudStorageDiscoveryState, .discovering)

        disco.checkItem(stream, in: "gallery.example.com", node: nil)
        let itemInfoRequest = try XCTUnwrap(stream.sentElements.last)
        XCTAssertEqual(itemInfoRequest.attributeStringValue(forName: "to"), "gallery.example.com")
        XCTAssertTrue(disco.read(withIQ: try makeDiscoResult(
            id: try XCTUnwrap(itemInfoRequest.attributeStringValue(forName: "id")),
            from: "gallery.example.com",
            galleryURL: "https://gallery.example.com/api/v1/"
        )))

        XCTAssertEqual(resolvedState, .available)
    }

    func testMissingConfigFlagResolvesToTelegramAttachmentFlow() {
        CommonConfigManager.shared.config.use_telegram_attachment_picker = nil

        XCTAssertTrue(CommonConfigManager.shared.isTelegramAttachmentPickerEnabled)

        let route = ChatAttachmentPickerRoutingPolicy.route(
            isTelegramAttachmentPickerEnabled: CommonConfigManager.shared.config.use_telegram_attachment_picker,
            isCloudStorageAvailable: true
        )

        XCTAssertEqual(route, .telegramAttachmentFlow)
    }

    func testRolloutPolicyRetainsLegacyFallbackWithoutProductSignoff() {
        let decision = ChatAttachmentPickerRolloutPolicy.decision(
            hasProductSignoffForDefaultOnRollout: false,
            sendParityVerified: true,
            focusedTestsPassed: true,
            appBuildPassed: true,
            manualSmokePassed: true,
            hasRollbackBlockers: false
        )

        XCTAssertEqual(decision, .retainLegacyFallback(.productSignoffMissing))
    }

    func testRolloutPolicyRetainsLegacyFallbackWhenManualSmokeIsMissing() {
        let decision = ChatAttachmentPickerRolloutPolicy.decision(
            hasProductSignoffForDefaultOnRollout: true,
            sendParityVerified: true,
            focusedTestsPassed: true,
            appBuildPassed: true,
            manualSmokePassed: false,
            hasRollbackBlockers: false
        )

        XCTAssertEqual(decision, .retainLegacyFallback(.manualSmokeMissing))
    }

    func testRolloutPolicyMarksLegacyRemovalEligibleOnlyAfterAllGatesPass() {
        let decision = ChatAttachmentPickerRolloutPolicy.decision(
            hasProductSignoffForDefaultOnRollout: true,
            sendParityVerified: true,
            focusedTestsPassed: true,
            appBuildPassed: true,
            manualSmokePassed: true,
            hasRollbackBlockers: false
        )

        XCTAssertEqual(decision, .eligibleToRemoveLegacyFallback)
    }

    func testRollbackRouteRemainsValidWhenLegacyFallbackIsRetained() {
        let decision = ChatAttachmentPickerRolloutPolicy.decision(
            hasProductSignoffForDefaultOnRollout: false,
            sendParityVerified: true,
            focusedTestsPassed: true,
            appBuildPassed: true,
            manualSmokePassed: true,
            hasRollbackBlockers: false
        )

        XCTAssertEqual(decision, .retainLegacyFallback(.productSignoffMissing))
        XCTAssertEqual(
            ChatAttachmentPickerRoutingPolicy.route(
                isTelegramAttachmentPickerEnabled: false,
                isCloudStorageAvailable: true
            ),
            .legacyImagePicker
        )
        XCTAssertEqual(
            ChatAttachmentPickerRoutingPolicy.route(
                isTelegramAttachmentPickerEnabled: true,
                isCloudStorageAvailable: true
            ),
            .telegramAttachmentFlow
        )
    }

    private func makeDiscoResult(
        id: String,
        from: String,
        galleryURL: String?
    ) throws -> XMPPIQ {
        let galleryConfiguration = galleryURL.map { galleryURL in
            """
            <x xmlns="jabber:x:data" type="result">
              <field var="FORM_TYPE"><value>urn:xabber:http:url</value></field>
              <field var="urn:xabber:http:url:mediagallery"><value>\(galleryURL)</value></field>
            </x>
            """
        } ?? ""
        let document = try DDXMLDocument(xmlString: """
        <iq type="result" id="\(id)" from="\(from)">
          <query xmlns="http://jabber.org/protocol/disco#info">
            \(galleryConfiguration)
          </query>
        </iq>
        """, options: 0)
        return XMPPIQ(from: try XCTUnwrap(document.rootElement()))
    }

}

private final class AttachmentDiscoveryCapturingXMPPStream: XMPPStream {
    private(set) var sentElements: [DDXMLElement] = []

    override func send(_ element: DDXMLElement) {
        sentElements.append((element.copy() as? DDXMLElement) ?? element)
    }
}
