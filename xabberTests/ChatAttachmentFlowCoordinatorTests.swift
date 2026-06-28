import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentFlowCoordinatorTests: XCTestCase {
    func testStartCreatesPickerAndDefaultsToGallery() throws {
        let factory = FakeSourceControllerFactory()
        let delegate = FakeFlowDelegate()
        let coordinator = makeCoordinator(factory: factory, delegate: delegate)

        coordinator.start()

        let picker = try XCTUnwrap(coordinator.pickerViewController)
        XCTAssertEqual(picker.activeSource, .gallery)
        XCTAssertEqual(factory.createdSources, [.gallery])
        XCTAssertEqual(delegate.failures, [])
    }

    func testStartConfiguresNativePageSheetPresentation() throws {
        var presentedViewController: UIViewController?
        let coordinator = makeCoordinator(presentationHandler: { _, presented, _, completion in
            presentedViewController = presented
            completion?()
        })

        coordinator.start()

        let picker = try XCTUnwrap(coordinator.pickerViewController)
        let navigationController = try XCTUnwrap(presentedViewController as? UINavigationController)
        XCTAssertIdentical(navigationController.viewControllers.first, picker)
        XCTAssertEqual(navigationController.modalPresentationStyle, .pageSheet)
        XCTAssertNil(navigationController.transitioningDelegate)
        XCTAssertFalse(navigationController.isModalInPresentation)
        XCTAssertFalse(navigationController.isNavigationBarHidden)
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

    func testStartRefreshesCloudStorageStatsForPickerOwner() {
        let quotaRefresher = FakeFlowQuotaRefresher()
        let coordinator = makeCoordinator(quotaRefresher: quotaRefresher)

        coordinator.start()

        XCTAssertEqual(quotaRefresher.calls.map(\.owner), [Self.makeContext().owner])
        XCTAssertEqual(quotaRefresher.calls.map(\.reason), [.screenOpen])
        XCTAssertEqual(quotaRefresher.calls.map(\.force), [true])
    }

    func testPickerUsesStandardNavigationTitleForActiveSource() throws {
        let coordinator = makeCoordinator()

        coordinator.start()
        let picker = try XCTUnwrap(coordinator.pickerViewController)

        XCTAssertEqual(picker.navigationItem.title, ChatAttachmentLocalization.string(.sourceGalleryTitle))

        coordinator.switchSource(to: .file)

        XCTAssertEqual(picker.navigationItem.title, ChatAttachmentLocalization.string(.sourceFileTitle))
    }

    func testSwitchSourceChangesActiveSourceWithoutChatViewController() throws {
        let factory = FakeSourceControllerFactory()
        let coordinator = makeCoordinator(factory: factory)

        coordinator.start()
        coordinator.switchSource(to: .file)

        let picker = try XCTUnwrap(coordinator.pickerViewController)
        XCTAssertEqual(picker.activeSource, .file)
        XCTAssertEqual(factory.createdSources, [.gallery, .file])
    }

    func testDefaultFactoryReturnsPlaceholderForContactSourceFallback() {
        let controller = DefaultChatAttachmentSourceControllerFactory().makeController(
            for: .contact,
            context: Self.makeContext()
        )

        XCTAssertEqual(controller.source, .contact)
        XCTAssertTrue(controller.viewController is ChatAttachmentPlaceholderSourceViewController)
    }

    func testSourceSelectionCountFlowsThroughSheetAndCoordinator() throws {
        let factory = FakeSourceControllerFactory()
        let coordinator = makeCoordinator(factory: factory)

        coordinator.start()
        let gallery = try XCTUnwrap(factory.controller(for: .gallery))
        gallery.emitSelectionCount(3)

        let picker = try XCTUnwrap(coordinator.pickerViewController)
        XCTAssertEqual(picker.selectedItemCount, 3)
        XCTAssertEqual(coordinator.selectedItemCount, 3)
    }

    func testDismissNotifiesDelegateAndReleasesSheetAndSources() throws {
        let factory = FakeSourceControllerFactory()
        let delegate = FakeFlowDelegate()
        let coordinator = makeCoordinator(factory: factory, delegate: delegate)

        coordinator.start()
        let picker = try XCTUnwrap(coordinator.pickerViewController)
        let gallery = try XCTUnwrap(factory.controller(for: .gallery))

        coordinator.dismiss(animated: false)

        XCTAssertEqual(delegate.dismissCount, 1)
        XCTAssertNil(coordinator.pickerViewController)
        XCTAssertNil(picker.delegate)
        XCTAssertNil(gallery.parent)
        XCTAssertNil(gallery.onSelectionCountChanged)
    }

    func testSuccessfulSendDismissesPickerAfterDismissalCompletionWithoutDismissDelegate() throws {
        let factory = FakeSourceControllerFactory()
        let delegate = FakeFlowDelegate()
        let sendCoordinator = FakeFlowSendCoordinator(result: .sent(referenceCount: 1))
        var dismissedController: UIViewController?
        var dismissCompletion: (() -> Void)?
        let coordinator = makeCoordinator(
            factory: factory,
            delegate: delegate,
            sendCoordinator: sendCoordinator,
            dismissalHandler: { controller, animated, completion in
                dismissedController = controller
                XCTAssertTrue(animated)
                dismissCompletion = completion
            }
        )

        coordinator.start()
        let picker = try XCTUnwrap(coordinator.pickerViewController)
        let navigationController = try XCTUnwrap(coordinator.pickerNavigationController)
        let gallery = try XCTUnwrap(factory.controller(for: .gallery))

        coordinator.chatAttachmentSheetViewController(
            picker,
            didRequestSend: [Self.preparedDraft(id: "asset:ready")],
            captionState: ChatAttachmentCaptionState(rawText: "Caption")
        )

        XCTAssertIdentical(dismissedController, navigationController)
        XCTAssertNil(picker.delegate)
        XCTAssertIdentical(coordinator.pickerViewController, picker)
        XCTAssertIdentical(gallery.parent, picker)
        XCTAssertEqual(delegate.dismissCount, 0)
        XCTAssertEqual(delegate.sendCount, 0)

        dismissCompletion?()

        XCTAssertNil(coordinator.pickerViewController)
        XCTAssertNil(coordinator.pickerNavigationController)
        XCTAssertNil(gallery.parent)
        XCTAssertEqual(delegate.dismissCount, 0)
        XCTAssertEqual(delegate.sendCount, 1)
    }

    func testBlockedSendKeepsPickerPresentedAndDoesNotDismiss() throws {
        let factory = FakeSourceControllerFactory()
        let delegate = FakeFlowDelegate()
        let sendCoordinator = FakeFlowSendCoordinator(result: .blocked(.cloudStorageUnavailable))
        var dismissalCount = 0
        let coordinator = makeCoordinator(
            factory: factory,
            delegate: delegate,
            sendCoordinator: sendCoordinator,
            dismissalHandler: { _, _, completion in
                dismissalCount += 1
                completion?()
            }
        )

        coordinator.start()
        let picker = try XCTUnwrap(coordinator.pickerViewController)
        let gallery = try XCTUnwrap(factory.controller(for: .gallery))

        coordinator.chatAttachmentSheetViewController(
            picker,
            didRequestSend: [Self.preparedDraft(id: "asset:ready")],
            captionState: ChatAttachmentCaptionState()
        )

        XCTAssertEqual(dismissalCount, 0)
        XCTAssertIdentical(coordinator.pickerViewController, picker)
        XCTAssertIdentical(gallery.parent, picker)
        XCTAssertEqual(delegate.dismissCount, 0)
        XCTAssertEqual(delegate.sendCount, 0)
        XCTAssertFalse(picker.statusBannerView.isHidden)
    }

    func testExhaustedQuotaPresentsCloudStorageAlertAndKeepsPickerPresented() throws {
        let factory = FakeSourceControllerFactory()
        let delegate = FakeFlowDelegate()
        let sendCoordinator = FakeFlowSendCoordinator(result: .cloudStorageQuotaExceeded(owner: Self.makeContext().owner))
        let quotaAlertPresenter = FakeFlowQuotaAlertPresenter()
        var openedCloudStorageOwner: String?
        var openedFromController: UIViewController?
        var dismissalCount = 0
        let coordinator = makeCoordinator(
            factory: factory,
            delegate: delegate,
            sendCoordinator: sendCoordinator,
            quotaAlertPresenter: quotaAlertPresenter,
            dismissalHandler: { _, _, completion in
                dismissalCount += 1
                completion?()
            },
            cloudStoragePresentationHandler: { source, owner in
                openedFromController = source
                openedCloudStorageOwner = owner
            }
        )

        coordinator.start()
        let picker = try XCTUnwrap(coordinator.pickerViewController)
        let navigationController = try XCTUnwrap(coordinator.pickerNavigationController)

        coordinator.chatAttachmentSheetViewController(
            picker,
            didRequestSend: [Self.preparedDraft(id: "asset:ready")],
            captionState: ChatAttachmentCaptionState()
        )

        XCTAssertEqual(dismissalCount, 0)
        XCTAssertIdentical(coordinator.pickerViewController, picker)
        XCTAssertEqual(delegate.dismissCount, 0)
        XCTAssertEqual(delegate.sendCount, 0)
        XCTAssertEqual(quotaAlertPresenter.presentedOwners, [Self.makeContext().owner])

        quotaAlertPresenter.triggerOpenCloudStorage()

        XCTAssertIdentical(openedFromController, navigationController)
        XCTAssertEqual(openedCloudStorageOwner, Self.makeContext().owner)
    }

    func testSuccessfulSendEndsEditingBeforeDismissal() throws {
        let sendCoordinator = FakeFlowSendCoordinator(result: .sent(referenceCount: 1))
        var endEditingCallCount = 0
        var didDismiss = false
        let coordinator = makeCoordinator(
            sendCoordinator: sendCoordinator,
            dismissalHandler: { _, _, completion in
                XCTAssertEqual(endEditingCallCount, 1)
                didDismiss = true
                completion?()
            },
            endEditingHandler: { picker, presentedController in
                endEditingCallCount += 1
                XCTAssertIdentical(presentedController, picker.navigationController)
            }
        )

        coordinator.start()
        let picker = try XCTUnwrap(coordinator.pickerViewController)

        coordinator.chatAttachmentSheetViewController(
            picker,
            didRequestSend: [Self.preparedDraft(id: "asset:ready")],
            captionState: ChatAttachmentCaptionState()
        )

        XCTAssertTrue(didDismiss)
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
        XCTAssertNil(coordinator.pickerViewController)
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
        delegate: ChatAttachmentFlowCoordinatorDelegate? = nil,
        sendCoordinator: ChatAttachmentSendCoordinating = FakeFlowSendCoordinator(result: .sent(referenceCount: 1)),
        quotaRefresher: ChatAttachmentQuotaRefreshing = FakeFlowQuotaRefresher(),
        quotaAlertPresenter: ChatAttachmentCloudStorageQuotaAlertPresenting = FakeFlowQuotaAlertPresenter(),
        dismissalHandler: ChatAttachmentFlowCoordinator.DismissalHandler? = nil,
        endEditingHandler: ChatAttachmentFlowCoordinator.EndEditingHandler? = nil,
        presentationHandler: ChatAttachmentFlowCoordinator.PresentationHandler? = nil,
        cloudStoragePresentationHandler: ChatAttachmentFlowCoordinator.CloudStoragePresentationHandler? = nil
    ) -> ChatAttachmentFlowCoordinator {
        let presenter = UIViewController()
        let coordinator = ChatAttachmentFlowCoordinator(
            presentingViewController: presenter,
            context: Self.makeContext(),
            sourceControllerFactory: factory,
            sendCoordinator: sendCoordinator,
            quotaRefresher: quotaRefresher,
            quotaAlertPresenter: quotaAlertPresenter,
            presentationHandler: { sourcePresenter, presented, animated, completion in
                _ = presenter
                if let presentationHandler {
                    presentationHandler(sourcePresenter, presented, animated, completion)
                } else {
                    completion?()
                }
            },
            dismissalHandler: dismissalHandler ?? { _, _, completion in completion?() },
            endEditingHandler: endEditingHandler ?? { _, _ in },
            cloudStoragePresentationHandler: cloudStoragePresentationHandler
                ?? { _, _ in }
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

    private static func preparedDraft(id: String) -> AttachmentDraft {
        let localURL = URL(fileURLWithPath: "/tmp/\(id.replacingOccurrences(of: ":", with: "-")).jpg")
        let preparedFile = AttachmentPreparedFile(
            localFileURL: localURL,
            referenceURL: localURL,
            filename: localURL.lastPathComponent,
            byteSize: 32,
            mediaType: "image/jpeg",
            dimensions: CGSize(width: 10, height: 10),
            duration: nil,
            videoPreviewKey: nil,
            videoOrientation: nil,
            videoDurationLabel: nil,
            videoPreviewLocalURL: nil,
            temporaryData: nil
        )
        return AttachmentDraft(
            id: id,
            source: .gallery,
            mediaKind: .image,
            thumbnailState: .none,
            filename: localURL.lastPathComponent,
            byteSize: 32,
            duration: nil,
            dimensions: CGSize(width: 10, height: 10),
            preparationState: .prepared(preparedFile)
        )
    }
}

private final class FakeFlowSendCoordinator: ChatAttachmentSendCoordinating {
    private let result: ChatAttachmentSendResult
    private(set) var sendCallCount = 0

    init(result: ChatAttachmentSendResult) {
        self.result = result
    }

    func send(
        drafts: [AttachmentDraft],
        captionState: ChatAttachmentCaptionState,
        context: ChatAttachmentFlowContext,
        completion: @escaping (ChatAttachmentSendResult) -> Void
    ) {
        sendCallCount += 1
        completion(result)
    }
}

private final class FakeFlowQuotaRefresher: ChatAttachmentQuotaRefreshing {
    struct Call {
        let owner: String
        let reason: CloudStorageQuotaRefreshReason
        let force: Bool
    }

    private(set) var calls: [Call] = []

    func refreshQuota(
        owner: String,
        reason: CloudStorageQuotaRefreshReason,
        force: Bool,
        completion: @escaping (CloudStorageQuotaRefreshResult) -> Void
    ) {
        calls.append(Call(owner: owner, reason: reason, force: force))
        completion(.success)
    }
}

private final class FakeFlowQuotaAlertPresenter: ChatAttachmentCloudStorageQuotaAlertPresenting {
    private(set) var presentedOwners: [String] = []
    private var openCloudStorage: (() -> Void)?

    func presentQuotaExceededAlert(
        from presenter: UIViewController,
        owner: String,
        openCloudStorage: @escaping () -> Void
    ) {
        presentedOwners.append(owner)
        self.openCloudStorage = openCloudStorage
    }

    func triggerOpenCloudStorage() {
        openCloudStorage?()
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
