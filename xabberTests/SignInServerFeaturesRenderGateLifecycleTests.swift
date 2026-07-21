import XCTest
import UIKit
import XMPPFramework
@testable import xabber

final class SignInServerFeaturesRenderGateLifecycleTests: XCTestCase {
    private var owner: String!
    private let endpoint = URL(string: "https://gallery.example/api/")!
    private var tokenClient: SignInServerFeaturesHoldingTokenAPIClient!
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        owner = "server-features-render-\(UUID().uuidString)@example.com"
        tokenClient = SignInServerFeaturesHoldingTokenAPIClient()
        XabberUploadManager.tokenAPIClient = tokenClient
        XabberUploadManager.networkPathMonitorFactory = { nil }
        XabberUploadManager.authorizationTimeoutInterval = 10
        AccountManager.shared.users.removeAll()
        AccountGalleryConfiguration(owner: owner).clearPersistedState()
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        AccountManager.shared.users.removeAll()
        AccountGalleryConfiguration(owner: owner).clearPersistedState()
        XabberUploadManager.tokenAPIClient = AlamofireCloudStorageTokenAPIClient()
        XabberUploadManager.networkPathMonitorFactory = { AccountNWPathMonitor() }
        XabberUploadManager.authorizationTimeoutInterval = 10
        tokenClient = nil
        owner = nil
        super.tearDown()
    }

    func testAvailabilityTransitionsCoalesceOffWindowAndCommitRowsAfterViewDidAppear() {
        XCTAssertTrue(Thread.isMainThread)
        let configuration = AccountGalleryConfiguration(owner: owner)
        let account = Account(
            jid: owner,
            queue: DispatchQueue(label: "SignInServerFeaturesRenderGateLifecycleTests.account")
        )
        account.configureStream()
        account.xmppStream.myJID = XMPPJID(string: "\(owner!)/ios")
        AccountManager.shared.users.append(account)
        let controller = SignInServerFeaturesViewController()
        controller.jid = owner
        controller.features = [ServerDiscoManager.retryableServerCapabilitiesMarker]
        var committedReloadCount = 0
        controller.fullTableRenderDidCommitForTesting = {
            committedReloadCount += 1
        }

        controller.loadViewIfNeeded()

        XCTAssertEqual(account.cloudStorage.availabilityRelay.value, .discovering)
        XCTAssertNil(controller.tableView.window)
        XCTAssertEqual(committedReloadCount, 0)
        XCTAssertEqual(visibleRowCount(in: controller), 3)

        configuration.storeBasicGalleryURL(endpoint.absoluteString)
        account.cloudStorage.markAvailabilityRetryableFailure(stage: .authorization)

        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .retryableFailure(stage: .authorization, endpoint: endpoint)
        )
        XCTAssertEqual(committedReloadCount, 0)
        XCTAssertEqual(visibleRowCount(in: controller), 5)

        let host = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.loadViewIfNeeded()
        host.addChild(controller)
        controller.beginAppearanceTransition(true, animated: false)
        controller.view.frame = host.view.bounds
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        host.view.layoutIfNeeded()
        controller.view.layoutIfNeeded()

        XCTAssertNotNil(controller.tableView.window)
        XCTAssertEqual(committedReloadCount, 0)

        account.cloudStorage.resolveAuthoritativeDiscovery(endpoint: endpoint)
        XCTAssertEqual(
            account.cloudStorage.availabilityRelay.value,
            .authorizing(endpoint: endpoint)
        )
        XCTAssertEqual(tokenClient.codeRequestCount, 1)

        configuration.storeToken("scoped-token", galleryType: .basic, baseURL: endpoint)
        account.cloudStorage.noteTokenResolved(galleryType: .basic, endpoint: endpoint)

        XCTAssertEqual(account.cloudStorage.availabilityRelay.value, .ready(endpoint: endpoint))
        XCTAssertEqual(committedReloadCount, 0)
        XCTAssertEqual(visibleRowCount(in: controller), 5)

        controller.endAppearanceTransition()
        controller.view.layoutIfNeeded()

        XCTAssertEqual(committedReloadCount, 1)
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 5)
        XCTAssertEqual(
            controller.tableView.numberOfRows(inSection: 0),
            visibleRowCount(in: controller)
        )

        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func visibleRowCount(
        in controller: SignInServerFeaturesViewController
    ) -> Int {
        controller.datasource.filter { !$0.isHidden }.count
    }
}

private final class SignInServerFeaturesHoldingTokenAPIClient: CloudStorageTokenAPIClient {
    private(set) var codeRequestCount = 0

    func requestCode(
        baseURL: URL,
        fullJID: String,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {
        codeRequestCount += 1
    }

    func exchangeCode(
        baseURL: URL,
        owner: String,
        code: String,
        completion: @escaping (CloudStorageQuotaAPIResponse) -> Void
    ) {}
}
