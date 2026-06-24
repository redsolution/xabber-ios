import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentFlowCoordinatorTests: XCTestCase {
    func testStartCreatesSheetAndDefaultsToGallery() throws {
        let factory = FakeSourceControllerFactory()
        let delegate = FakeFlowDelegate()
        let coordinator = makeCoordinator(factory: factory, delegate: delegate)

        coordinator.start()

        let sheet = try XCTUnwrap(coordinator.sheetViewController)
        XCTAssertEqual(sheet.activeSource, .gallery)
        XCTAssertEqual(factory.createdSources, [.gallery])
        XCTAssertEqual(delegate.failures, [])
    }

    func testStartPresentsSheetAnimated() {
        let presenter = UIViewController()
        var capturedAnimated: Bool?
        let coordinator = ChatAttachmentFlowCoordinator(
            presentingViewController: presenter,
            context: Self.makeContext(),
            sourceControllerFactory: FakeSourceControllerFactory(),
            presentationHandler: { _, _, animated, completion in
                capturedAnimated = animated
                completion?()
            }
        )

        coordinator.start()

        XCTAssertEqual(capturedAnimated, true)
    }

    func testSwitchSourceChangesActiveSourceWithoutChatViewController() throws {
        let factory = FakeSourceControllerFactory()
        let coordinator = makeCoordinator(factory: factory)

        coordinator.start()
        coordinator.switchSource(to: .file)

        let sheet = try XCTUnwrap(coordinator.sheetViewController)
        XCTAssertEqual(sheet.activeSource, .file)
        XCTAssertEqual(factory.createdSources, [.gallery, .file])
    }

    func testSourceSelectionCountFlowsThroughSheetAndCoordinator() throws {
        let factory = FakeSourceControllerFactory()
        let coordinator = makeCoordinator(factory: factory)

        coordinator.start()
        let gallery = try XCTUnwrap(factory.controller(for: .gallery))
        gallery.emitSelectionCount(3)

        let sheet = try XCTUnwrap(coordinator.sheetViewController)
        XCTAssertEqual(sheet.selectedItemCount, 3)
        XCTAssertEqual(coordinator.selectedItemCount, 3)
    }

    func testDismissNotifiesDelegateAndReleasesSheetAndSources() throws {
        let factory = FakeSourceControllerFactory()
        let delegate = FakeFlowDelegate()
        let coordinator = makeCoordinator(factory: factory, delegate: delegate)

        coordinator.start()
        let sheet = try XCTUnwrap(coordinator.sheetViewController)
        let gallery = try XCTUnwrap(factory.controller(for: .gallery))

        coordinator.dismiss(animated: false)

        XCTAssertEqual(delegate.dismissCount, 1)
        XCTAssertNil(coordinator.sheetViewController)
        XCTAssertNil(sheet.delegate)
        XCTAssertNil(gallery.parent)
        XCTAssertNil(gallery.onSelectionCountChanged)
    }

    func testMissingPresenterFailsCoordinatorStart() {
        let delegate = FakeFlowDelegate()
        var presenter: UIViewController? = UIViewController()
        let coordinator = ChatAttachmentFlowCoordinator(
            presentingViewController: presenter!,
            context: Self.makeContext()
        )
        coordinator.delegate = delegate
        presenter = nil

        coordinator.start()

        XCTAssertEqual(delegate.failures, [.missingPresenter])
        XCTAssertNil(coordinator.sheetViewController)
    }

    func testChatViewControllerDelegateClearsRetainedCoordinatorOnDismissAndSend() {
        let chat = ChatViewController()
        let dismissCoordinator = makeCoordinator()
        chat.chatAttachmentFlowCoordinator = dismissCoordinator

        chat.chatAttachmentFlowCoordinatorDidDismiss(dismissCoordinator)

        XCTAssertNil(chat.chatAttachmentFlowCoordinator)

        let sendCoordinator = makeCoordinator()
        chat.chatAttachmentFlowCoordinator = sendCoordinator

        chat.chatAttachmentFlowCoordinatorDidSend(sendCoordinator)

        XCTAssertNil(chat.chatAttachmentFlowCoordinator)
    }

    private func makeCoordinator(
        factory: ChatAttachmentSourceControllerFactory = FakeSourceControllerFactory(),
        delegate: ChatAttachmentFlowCoordinatorDelegate? = nil
    ) -> ChatAttachmentFlowCoordinator {
        let presenter = UIViewController()
        let coordinator = ChatAttachmentFlowCoordinator(
            presentingViewController: presenter,
            context: Self.makeContext(),
            sourceControllerFactory: factory,
            presentationHandler: { _, _, _, completion in
                _ = presenter
                completion?()
            }
        )
        coordinator.delegate = delegate
        return coordinator
    }

    private static func makeContext() -> ChatAttachmentFlowContext {
        ChatAttachmentFlowContext(
            owner: "alice@example.com",
            jid: "bob@example.com",
            conversationType: .regular,
            forwardedMessageIds: ["forwarded-1"]
        )
    }
}

private final class FakeFlowDelegate: ChatAttachmentFlowCoordinatorDelegate {
    var sendCount = 0
    var dismissCount = 0
    var premiumOwners: [String] = []
    var failures: [ChatAttachmentFlowError] = []

    func chatAttachmentFlowCoordinatorDidSend(_ coordinator: ChatAttachmentFlowCoordinator) {
        sendCount += 1
    }

    func chatAttachmentFlowCoordinatorDidDismiss(_ coordinator: ChatAttachmentFlowCoordinator) {
        dismissCount += 1
    }

    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didRequestPremiumFor owner: String
    ) {
        premiumOwners.append(owner)
    }

    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didFailWith error: ChatAttachmentFlowError
    ) {
        failures.append(error)
    }
}

private final class FakeSourceControllerFactory: ChatAttachmentSourceControllerFactory {
    private var controllers: [ChatAttachmentSource: WeakFakeSourceController] = [:]
    private(set) var createdSources: [ChatAttachmentSource] = []

    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        let controller = FakeSourceController(source: source)
        controllers[source] = WeakFakeSourceController(controller)
        createdSources.append(source)
        return controller
    }

    func controller(for source: ChatAttachmentSource) -> FakeSourceController? {
        controllers[source]?.controller
    }
}

private final class WeakFakeSourceController {
    weak var controller: FakeSourceController?

    init(_ controller: FakeSourceController) {
        self.controller = controller
    }
}

private final class FakeSourceController: UIViewController, ChatAttachmentSourceControlling {
    let source: ChatAttachmentSource
    var onSelectionCountChanged: ((Int) -> Void)?

    var viewController: UIViewController {
        self
    }

    init(source: ChatAttachmentSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func emitSelectionCount(_ count: Int) {
        onSelectionCountChanged?(count)
    }
}
