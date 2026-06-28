import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentSheetPresentationTests: XCTestCase {
    func testPageSheetStyleConfiguresLargeOnlyNativeSheet() {
        let picker = UIViewController()

        ChatAttachmentPickerPageSheetStyle.apply(to: picker)

        XCTAssertEqual(picker.modalPresentationStyle, .pageSheet)
        XCTAssertNil(picker.transitioningDelegate)
        XCTAssertFalse(picker.isModalInPresentation)
        XCTAssertEqual(picker.sheetPresentationController?.detents.count, 1)
        XCTAssertEqual(picker.sheetPresentationController?.selectedDetentIdentifier, .large)
        XCTAssertEqual(picker.sheetPresentationController?.prefersGrabberVisible, false)
        XCTAssertEqual(
            picker.sheetPresentationController?.preferredCornerRadius,
            ChatAttachmentSheetGlassStyle.sheetCornerRadius
        )
    }

    func testPickerViewControllerEmbedsSourcesInRootContent() throws {
        let factory = Task5FakeSourceControllerFactory()
        let picker = ChatAttachmentPickerViewController(
            context: Self.makeContext(),
            sourceControllerFactory: factory
        )

        picker.loadViewIfNeeded()

        let gallery = try XCTUnwrap(factory.controller(for: .gallery))
        XCTAssertTrue(picker.sourceContainerView.isDescendant(of: picker.view))
        XCTAssertEqual(gallery.view.superview, picker.sourceContainerView)
    }

    func testPickerSourceContentStartsAtTopWithoutGlassGap() throws {
        let factory = Task5FakeSourceControllerFactory()
        let picker = ChatAttachmentPickerViewController(
            context: Self.makeContext(),
            sourceControllerFactory: factory
        )

        picker.loadViewIfNeeded()
        picker.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        picker.view.layoutIfNeeded()

        let gallery = try XCTUnwrap(factory.controller(for: .gallery))
        XCTAssertEqual(picker.sourceContainerView.frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(gallery.view.convert(gallery.view.bounds, to: picker.view).minY, 0, accuracy: 0.001)
    }

    func testPickerSourceContentExtendsBehindBottomControls() throws {
        let factory = Task5FakeSourceControllerFactory()
        let picker = ChatAttachmentPickerViewController(
            context: Self.makeContext(),
            sourceControllerFactory: factory
        )

        picker.loadViewIfNeeded()
        picker.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        picker.view.layoutIfNeeded()

        let gallery = try XCTUnwrap(factory.controller(for: .gallery))
        XCTAssertEqual(picker.sourceContainerView.frame.maxY, picker.view.bounds.maxY, accuracy: 0.001)
        XCTAssertEqual(gallery.view.convert(gallery.view.bounds, to: picker.view).maxY, picker.view.bounds.maxY, accuracy: 0.001)
        XCTAssertGreaterThan(picker.sourceContainerView.frame.maxY, picker.bottomControlsContainerView.frame.minY)
    }

    func testSheetGlassStyleUsesNativeGlassWhenAvailable() throws {
        let effect = ChatAttachmentSheetGlassStyle.makeEffect(interactive: false)

        if #available(iOS 26.0, *) {
            let glassEffect = try XCTUnwrap(effect as? UIGlassEffect)
            XCTAssertFalse(glassEffect.isInteractive)
            XCTAssertEqual(glassEffect.tintColor, XabberGlassStyle.nativeGlassTintColor)
        } else {
            XCTAssertTrue(effect is UIBlurEffect)
        }
        XCTAssertTrue(ChatAttachmentSheetGlassStyle.makeEffect(prefersNativeGlass: false) is UIBlurEffect)
    }

    func testPickerRootViewHostsGlassBackgroundBehindContent() {
        let picker = ChatAttachmentPickerViewController(
            context: Self.makeContext(),
            sourceControllerFactory: Task5FakeSourceControllerFactory()
        )

        picker.loadViewIfNeeded()

        XCTAssertEqual(picker.view.backgroundColor ?? .clear, .clear)
        XCTAssertFalse(picker.view.isOpaque)
        XCTAssertTrue(picker.sheetBackgroundEffectView.superview === picker.view)
        XCTAssertTrue(picker.view.subviews.first === picker.sheetBackgroundEffectView)
        XCTAssertFalse(picker.sheetBackgroundEffectView.isUserInteractionEnabled)
        XCTAssertGreaterThan(
            picker.view.subviews.firstIndex(of: picker.sourceContainerView) ?? 0,
            picker.view.subviews.firstIndex(of: picker.sheetBackgroundEffectView) ?? 0
        )
    }

    func testPickerRootViewRoundsTopCornersOnly() {
        let picker = ChatAttachmentPickerViewController(
            context: Self.makeContext(),
            sourceControllerFactory: Task5FakeSourceControllerFactory()
        )

        picker.loadViewIfNeeded()

        XCTAssertEqual(picker.view.layer.cornerRadius, 18, accuracy: 0.001)
        XCTAssertEqual(
            picker.view.layer.maskedCorners,
            [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        )
        XCTAssertTrue(picker.view.layer.masksToBounds)
    }

    func testPickerLowerControlsAreTransparentOverGlassBackground() {
        let picker = ChatAttachmentPickerViewController(
            context: Self.makeContext(),
            sourceControllerFactory: Task5FakeSourceControllerFactory()
        )

        picker.loadViewIfNeeded()

        XCTAssertEqual(picker.sourceBarView.backgroundColor ?? .clear, .clear)
        XCTAssertEqual(picker.selectionPreviewBarView.backgroundColor ?? .clear, .clear)
        XCTAssertEqual(picker.selectionComposerBarView.backgroundColor ?? .clear, .clear)
        XCTAssertEqual(picker.bottomControlsContainerView.backgroundColor ?? .clear, .clear)
    }

    func testPickerSourceBarUsesFloatingBottomBarMetricsAtBottom() {
        let picker = ChatAttachmentPickerViewController(
            context: Self.makeContext(),
            sourceControllerFactory: Task5FakeSourceControllerFactory()
        )

        picker.loadViewIfNeeded()
        picker.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        picker.view.layoutIfNeeded()

        XCTAssertEqual(
            picker.bottomControlsContainerView.frame.height,
            NativeGlassBarStyle.minimumHeight + 8 + NativeGlassBarStyle.bottomOffset,
            accuracy: 0.001
        )
        XCTAssertEqual(picker.sourceBarView.frame.height, NativeGlassBarStyle.minimumHeight, accuracy: 0.001)
        XCTAssertEqual(picker.sourceBarView.frame.minX, NativeGlassBarStyle.horizontalInset, accuracy: 0.001)
        XCTAssertEqual(
            picker.sourceBarView.frame.maxX,
            picker.view.bounds.width - NativeGlassBarStyle.horizontalInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            picker.sourceBarView.frame.maxY,
            picker.bottomControlsContainerView.bounds.maxY - NativeGlassBarStyle.bottomOffset,
            accuracy: 0.001
        )
    }

    func testRepeatedOpenDismissReleasesPickerSources() throws {
        for _ in 0..<2 {
            let factory = Task5FakeSourceControllerFactory()
            let delegate = Task5FakeFlowDelegate()
            let presenter = UIViewController()
            let coordinator = ChatAttachmentFlowCoordinator(
                presentingViewController: presenter,
                context: Self.makeContext(),
                sourceControllerFactory: factory,
                presentationHandler: { _, _, _, completion in
                    completion?()
                }
            )
            coordinator.delegate = delegate

            coordinator.start()

            let picker = try XCTUnwrap(coordinator.pickerViewController)
            let gallery = try XCTUnwrap(factory.controller(for: .gallery))
            XCTAssertNil(picker.transitioningDelegate)

            coordinator.dismiss(animated: false)

            XCTAssertEqual(delegate.dismissCount, 1)
            XCTAssertNil(coordinator.pickerViewController)
            XCTAssertNil(picker.delegate)
            XCTAssertNil(gallery.parent)
            XCTAssertNil(gallery.onSelectionCountChanged)
        }
    }

    private static func makeContext() -> ChatAttachmentFlowContext {
        ChatAttachmentFlowContext(
            owner: "alice@example.com",
            jid: "bob@example.com",
            conversationType: .regular,
            forwardedMessageIds: []
        )
    }
}

private final class Task5FakeFlowDelegate: ChatAttachmentFlowCoordinatorDelegate {
    var dismissCount = 0

    func chatAttachmentFlowCoordinatorDidSend(_ coordinator: ChatAttachmentFlowCoordinator) {}

    func chatAttachmentFlowCoordinatorDidDismiss(_ coordinator: ChatAttachmentFlowCoordinator) {
        dismissCount += 1
    }

    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didRequestPremiumFor owner: String
    ) {}

    func chatAttachmentFlowCoordinator(
        _ coordinator: ChatAttachmentFlowCoordinator,
        didFailWith error: ChatAttachmentFlowError
    ) {}
}

private final class Task5FakeSourceControllerFactory: ChatAttachmentSourceControllerFactory {
    private var controllers: [ChatAttachmentSource: Task5WeakSourceController] = [:]

    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        let controller = Task5FakeSourceController(source: source)
        controllers[source] = Task5WeakSourceController(controller)
        return controller
    }

    func controller(for source: ChatAttachmentSource) -> Task5FakeSourceController? {
        controllers[source]?.controller
    }
}

private final class Task5WeakSourceController {
    weak var controller: Task5FakeSourceController?

    init(_ controller: Task5FakeSourceController) {
        self.controller = controller
    }
}

private final class Task5FakeSourceController: UIViewController, ChatAttachmentSourceControlling {
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
}
