import UIKit
import XCTest
@testable import xabber

@MainActor
final class QRContactAddCompletionRegressionTests: XCTestCase {
    private let owner = "juliet@example.test"
    private let contact = "romeo@example.test"

    func testContactCompletionUsesModalContainerHostAfterDismissalDetachesChild() async throws {
        let host = ContactChatHostNavigationController(rootViewController: UIViewController())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.loadViewIfNeeded()
        let controller = DismissingContactController()
        let modal = ContactModalNavigationController(rootViewController: controller)
        modal.simulatedPresenter = host
        controller.beforeDismissCompletion = { modal.simulatedPresenter = nil }
        let routed = expectation(description: "completed contact opens on surviving modal host")
        host.onChat = { _ in routed.fulfill() }
        defer {
            host.chats.forEach { $0.performTerminalChatResourceTeardownForTesting() }
            window.isHidden = true
            window.rootViewController = nil
        }

        controller.closeAndDisplayContact(jid: contact, owner: owner)
        await fulfillment(of: [routed], timeout: 2)

        XCTAssertEqual(controller.dismissCount, 1)
        XCTAssertNil(modal.simulatedPresenter, "the modal host has detached before completion runs")
        XCTAssertEqual(controller.detachedPresentationControllerReads, 0,
                       "a dismissed child's manufactured presentation controller is not a route owner")
        let chat = try XCTUnwrap(host.chats.first)
        XCTAssertEqual(host.chats.count, 1)
        XCTAssertEqual(chat.owner, owner)
        XCTAssertEqual(chat.jid, contact)
        XCTAssertEqual(chat.conversationType, expectedConversationType)
    }

    func testContactCompletionWithoutSurvivingHostDoesNotManufacturePresentationController() async {
        let controller = DismissingContactController()
        let finished = expectation(description: "dismissal callback completes without a presentation host")
        controller.afterDismissCompletion = { finished.fulfill() }

        controller.closeAndDisplayContact(jid: contact, owner: owner)
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(controller.dismissCount, 1)
        XCTAssertEqual(controller.detachedPresentationControllerReads, 0)
    }

    func testRepeatedContactSuccessDismissesAndRoutesDelegateOnlyOnce() async {
        let controller = DismissingContactController()
        let delegate = ContactChatRouteDelegate()
        controller.leftMenuSelectRootCategoryDelegate = delegate
        let routed = expectation(description: "delegate routes completed contact")
        routed.assertForOverFulfill = false
        delegate.onRoute = { routed.fulfill() }

        controller.closeAndDisplayContact(jid: contact, owner: owner)
        controller.closeAndDisplayContact(jid: contact, owner: owner)
        await fulfillment(of: [routed], timeout: 1)
        // Drain the second queued close before assessing idempotence.
        let drained = expectation(description: "queued completion work drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)

        XCTAssertEqual(controller.dismissCount, 1)
        XCTAssertEqual(delegate.routes.count, 1)
        XCTAssertEqual(delegate.routes.first?.owner, owner)
        XCTAssertEqual(delegate.routes.first?.jid, contact)
        XCTAssertEqual(delegate.routes.first?.conversationType, expectedConversationType)
        XCTAssertEqual(controller.detachedPresentationControllerReads, 0)
    }

    func testScannedContactKeepsExistingNavigationDelegate() throws {
        let scanner = ContactScannerWithoutCapture()
        let delegate = ContactChatRouteDelegate()
        scanner.leftMenuSelectRootCategoryDelegate = delegate
        let navigation = scannerNavigation(scanner)

        scanner.found(code: "xmpp:\(contact)/mobile")

        let destination = try XCTUnwrap(navigation.contactRoutes.first)
        XCTAssertEqual(destination.contactJid.value, contact)
        XCTAssertTrue(destination.leftMenuSelectRootCategoryDelegate === delegate)
    }

    func testScannedContactPreservesExplicitAccount() throws {
        let scanner = ContactScannerWithoutCapture()
        scanner.accountJid = owner
        let navigation = scannerNavigation(scanner)

        scanner.found(code: "xmpp:\(contact)")

        let destination = try XCTUnwrap(navigation.contactRoutes.first)
        XCTAssertEqual(destination.accountJid, owner)
    }

    func testSettingsScanButtonPassesSelectedAccountWithoutStartingCamera() throws {
        let card = QRCodeViewController()
        card.presentationMode = .settingsAccountCard
        card.jid = owner
        card.stringValue = SettingsAccountQRCodePayload.string(for: owner)
        let navigation = ContactSettingsNavigationController(rootViewController: card)
        card.loadViewIfNeeded()
        let scan = try XCTUnwrap(button(withIdentifier: "settings.account_qr.scan", in: card.view))

        scan.sendActions(for: .touchUpInside)

        let scanner = try XCTUnwrap(navigation.scanners.first)
        XCTAssertEqual(navigation.scanners.count, 1)
        XCTAssertEqual(scanner.accountJid, owner)
        XCTAssertFalse(scanner.isViewLoaded, "the route fixture must not configure a camera")
    }

    func testQueuedDuplicateScanResultsProduceOnlyOneContactDestination() {
        let scanner = ContactScannerWithoutCapture()
        // UIKit can keep the old scanner attached during an animated stack
        // replacement; retain that state until the queued callbacks drain.
        let navigation = scannerNavigation(scanner)

        scanner.found(code: "xmpp:\(contact)")
        scanner.found(code: "xmpp:\(contact)")

        XCTAssertEqual(navigation.contactRoutes.count, 1)
    }

    func testContactCompletionDoesNotRouteIntoHostRemovedDuringDismissal() async {
        let host = ContactChatHostNavigationController(rootViewController: UIViewController())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        host.loadViewIfNeeded()
        let controller = DismissingContactController()
        let modal = ContactModalNavigationController(rootViewController: controller)
        modal.simulatedPresenter = host
        let dismissed = expectation(description: "dismissal detached the captured host")
        controller.beforeDismissCompletion = {
            modal.simulatedPresenter = nil
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.afterDismissCompletion = { dismissed.fulfill() }

        controller.closeAndDisplayContact(jid: contact, owner: owner)
        await fulfillment(of: [dismissed], timeout: 1)

        XCTAssertTrue(host.chats.isEmpty)
        XCTAssertEqual(controller.detachedPresentationControllerReads, 0)
    }

    private func button(withIdentifier identifier: String, in root: UIView) -> UIButton? {
        if root.accessibilityIdentifier == identifier { return root as? UIButton }
        for child in root.subviews {
            if let found = button(withIdentifier: identifier, in: child) { return found }
        }
        return nil
    }

    private var expectedConversationType: ClientSynchronizationManager.ConversationType {
        ClientSynchronizationManager.ConversationType(
            rawValue: CommonConfigManager.shared.config.locked_conversation_type
        ) ?? .regular
    }

    private func scannerNavigation(_ scanner: QRCodeScannerViewController) -> ContactScannerNavigationController {
        let navigation = ContactScannerNavigationController(rootViewController: UIViewController())
        navigation.setViewControllers([navigation.viewControllers[0], scanner], animated: false)
        navigation.recordsContactRoutes = true
        return navigation
    }
}

@MainActor
private final class DismissingContactController: AddNewContactViewController {
    var dismissCount = 0
    var didFinishDismissal = false
    var detachedPresentationControllerReads = 0
    var beforeDismissCompletion: (() -> Void)?
    var afterDismissCompletion: (() -> Void)?

    override func configure() {}
    override func subscribe() {}

    override var presentationController: UIPresentationController? {
        if didFinishDismissal { detachedPresentationControllerReads += 1 }
        // Model the real UIKit detachment without returning a nonnull Objective-C
        // presentation controller whose presentingViewController is actually nil.
        // This exposes lost routing on the old code without killing XCTest.
        return nil
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        dismissCount += 1
        didFinishDismissal = true
        beforeDismissCompletion?()
        completion?()
        afterDismissCompletion?()
    }
}

@MainActor
private final class ContactModalNavigationController: UINavigationController {
    var simulatedPresenter: UIViewController?
    override var presentingViewController: UIViewController? { simulatedPresenter }
}

@MainActor
private final class ContactChatHostNavigationController: UINavigationController {
    var chats: [ChatViewController] = []
    var onChat: ((ChatViewController) -> Void)?

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        if let chat = viewController as? ChatViewController {
            chats.append(chat)
            onChat?(chat)
        } else {
            super.pushViewController(viewController, animated: animated)
        }
    }
}

@MainActor
private final class ContactScannerWithoutCapture: QRCodeScannerViewController {
    override func configure() {}
}

@MainActor
private final class ContactScannerNavigationController: UINavigationController {
    var recordsContactRoutes = false
    var contactRoutes: [AddNewContactViewController] = []

    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        if recordsContactRoutes, let destination = viewControllers.last as? AddNewContactViewController {
            contactRoutes.append(destination)
        } else {
            super.setViewControllers(viewControllers, animated: animated)
        }
    }
}

@MainActor
private final class ContactChatRouteDelegate: LeftMenuSelectRootScreenDelegate {
    struct Route {
        let owner: String
        let jid: String
        let conversationType: ClientSynchronizationManager.ConversationType
    }
    var routes: [Route] = []
    var onRoute: (() -> Void)?

    func selectRootScreenAndCategory(screen key: String, category: String?) -> Bool { true }

    func openChatlistWithChat(
        owner: String,
        jid: String,
        conversationType: ClientSynchronizationManager.ConversationType,
        openMessageRequest: ChatOpenMessageRequest?,
        navigationSource: ChatOpenNavigationSource,
        configure: ((ChatViewController?) -> Void)?
    ) -> Bool {
        routes.append(Route(owner: owner, jid: jid, conversationType: conversationType))
        onRoute?()
        return true
    }
}

@MainActor
private final class ContactSettingsNavigationController: UINavigationController {
    var scanners: [QRCodeScannerViewController] = []

    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        if let scanner = viewController as? QRCodeScannerViewController {
            // Observe the factory result without installing/loading its camera.
            scanners.append(scanner)
        } else {
            super.pushViewController(viewController, animated: animated)
        }
    }
}
