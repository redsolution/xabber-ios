import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentSourceBarTests: XCTestCase {
    func testDefaultSourceBarSelectsGalleryAndShowsDisabledFutureSources() throws {
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: Task6FakeSourceControllerFactory()
        )

        sheet.loadViewIfNeeded()

        let galleryButton = try XCTUnwrap(sheet.sourceBarView.button(for: .gallery))
        let fileButton = try XCTUnwrap(sheet.sourceBarView.button(for: .file))
        let locationButton = try XCTUnwrap(sheet.sourceBarView.button(for: .geolocation))
        let contactButton = try XCTUnwrap(sheet.sourceBarView.button(for: .contact))

        XCTAssertEqual(sheet.sourceBarView.visibleSources, [.gallery, .file, .geolocation, .contact])
        XCTAssertTrue(galleryButton.isSelected)
        XCTAssertTrue(galleryButton.isEnabled)
        XCTAssertFalse(fileButton.isSelected)
        XCTAssertTrue(fileButton.isEnabled)
        XCTAssertFalse(locationButton.isEnabled)
        XCTAssertFalse(contactButton.isEnabled)
    }

    func testTappingFileRoutesSheetToFileAndUpdatesSelectedState() throws {
        let factory = Task6FakeSourceControllerFactory()
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: factory
        )
        sheet.loadViewIfNeeded()

        try XCTUnwrap(sheet.sourceBarView.button(for: .file)).sendActions(for: .touchUpInside)

        XCTAssertEqual(sheet.activeSource, .file)
        XCTAssertEqual(factory.createdSources, [.gallery, .file])
        XCTAssertFalse(try XCTUnwrap(sheet.sourceBarView.button(for: .gallery)).isSelected)
        XCTAssertTrue(try XCTUnwrap(sheet.sourceBarView.button(for: .file)).isSelected)
    }

    func testSourceBarUsesGlassCapsuleWithIconOnlyButtonsAndSeparateDismissButton() throws {
        let sourceBar = ChatAttachmentSourceBarView()
        sourceBar.configure(
            configuration: .default,
            selectedSource: .gallery
        )

        let galleryButton = try XCTUnwrap(sourceBar.button(for: .gallery))
        let fileButton = try XCTUnwrap(sourceBar.button(for: .file))

        XCTAssertTrue(sourceBar.sourceSurfaceView.superview === sourceBar)
        XCTAssertTrue(galleryButton.isDescendant(of: sourceBar.sourceSurfaceView.contentView))
        XCTAssertTrue(fileButton.isDescendant(of: sourceBar.sourceSurfaceView.contentView))
        XCTAssertNil(galleryButton.title(for: .normal))
        XCTAssertNil(galleryButton.configuration?.title)
        XCTAssertNotNil(galleryButton.image(for: .normal) ?? galleryButton.configuration?.image)
        XCTAssertNil(fileButton.configuration?.title)
        XCTAssertEqual(sourceBar.sourceSurfaceView.layer.cornerRadius, NativeGlassBarStyle.cornerRadius, accuracy: 0.001)

        XCTAssertTrue(sourceBar.dismissButton.superview === sourceBar)
        XCTAssertEqual(sourceBar.dismissButton.accessibilityIdentifier, "chatAttachmentSheet.sourceBar.dismissButton")
        XCTAssertEqual(sourceBar.dismissButton.accessibilityLabel, ChatAttachmentLocalization.string(.galleryDismissAction))
        XCTAssertNotNil(sourceBar.dismissButton.image(for: .normal) ?? sourceBar.dismissButton.configuration?.image)
    }

    func testDismissButtonIsLaidOutBeforeSourceCapsule() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: NativeGlassBarStyle.buttonSize))
        let sourceBar = ChatAttachmentSourceBarView()
        sourceBar.configure(
            configuration: .default,
            selectedSource: .gallery
        )

        container.addSubview(sourceBar)
        NSLayoutConstraint.activate([
            sourceBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sourceBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sourceBar.topAnchor.constraint(equalTo: container.topAnchor),
            sourceBar.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.layoutIfNeeded()

        XCTAssertEqual(sourceBar.dismissButton.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(sourceBar.dismissButton.frame.width, NativeGlassBarStyle.buttonSize, accuracy: 0.001)
        XCTAssertEqual(
            sourceBar.sourceSurfaceView.frame.minX,
            NativeGlassBarStyle.buttonSize + NativeGlassBarStyle.interItemSpacing,
            accuracy: 0.001
        )
        XCTAssertLessThan(sourceBar.dismissButton.frame.maxX, sourceBar.sourceSurfaceView.frame.minX)
        XCTAssertEqual(sourceBar.sourceSurfaceView.frame.maxX, sourceBar.bounds.maxX, accuracy: 0.001)
    }

    func testSelectedSourceTintComesFromFlowContext() throws {
        let selectedTintColor = UIColor(red: 0.9, green: 0.1, blue: 0.5, alpha: 1)
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(composerTintColor: selectedTintColor),
            sourceControllerFactory: Task6FakeSourceControllerFactory()
        )

        sheet.loadViewIfNeeded()

        let galleryButton = try XCTUnwrap(sheet.sourceBarView.button(for: .gallery))
        XCTAssertEqual(galleryButton.tintColor, selectedTintColor)
        XCTAssertEqual(galleryButton.configuration?.baseForegroundColor, selectedTintColor)
    }

    func testDismissButtonRequestsPickerDismissal() {
        let sourceBar = ChatAttachmentSourceBarView()
        let delegate = Task6SourceBarDelegateSpy()
        sourceBar.delegate = delegate

        sourceBar.dismissButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(delegate.dismissRequestCount, 1)
    }

    func testSourceSwitchingPreservesGalleryControllerAndSelectionState() throws {
        let factory = Task6FakeSourceControllerFactory()
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: factory
        )
        sheet.loadViewIfNeeded()

        let gallery = try XCTUnwrap(factory.controller(for: .gallery))
        gallery.emitSelectionCount(4)

        sheet.switchSource(to: .file)
        sheet.switchSource(to: .gallery)

        XCTAssertTrue(factory.controller(for: .gallery) === gallery)
        XCTAssertEqual(factory.createdSources, [.gallery, .file])
        XCTAssertEqual(sheet.activeSource, .gallery)
        XCTAssertEqual(sheet.selectedItemCount, 4)
    }

    func testDisabledFutureSourcesAreVisibleButDoNotRoute() throws {
        let factory = Task6FakeSourceControllerFactory()
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: factory
        )
        sheet.loadViewIfNeeded()

        let locationButton = try XCTUnwrap(sheet.sourceBarView.button(for: .geolocation))
        let contactButton = try XCTUnwrap(sheet.sourceBarView.button(for: .contact))
        XCTAssertFalse(locationButton.isEnabled)
        XCTAssertFalse(contactButton.isEnabled)

        locationButton.sendActions(for: .touchUpInside)
        contactButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(sheet.activeSource, .gallery)
        XCTAssertEqual(factory.createdSources, [.gallery])
        XCTAssertTrue(try XCTUnwrap(sheet.sourceBarView.button(for: .gallery)).isSelected)
        XCTAssertFalse(locationButton.isSelected)
        XCTAssertFalse(contactButton.isSelected)
    }

    private static func makeContext(composerTintColor: UIColor = .systemBlue) -> ChatAttachmentFlowContext {
        ChatAttachmentFlowContext(
            owner: "alice@example.com",
            jid: "bob@example.com",
            conversationType: .regular,
            forwardedMessageIds: [],
            composerTintColor: composerTintColor
        )
    }
}

private final class Task6SourceBarDelegateSpy: ChatAttachmentSourceBarViewDelegate {
    var dismissRequestCount = 0

    func chatAttachmentSourceBarView(
        _ view: ChatAttachmentSourceBarView,
        didSelect source: ChatAttachmentSource
    ) {}

    func chatAttachmentSourceBarViewDidRequestDismiss(_ view: ChatAttachmentSourceBarView) {
        dismissRequestCount += 1
    }
}

private final class Task6FakeSourceControllerFactory: ChatAttachmentSourceControllerFactory {
    private var controllers: [ChatAttachmentSource: Task6WeakSourceController] = [:]
    private(set) var createdSources: [ChatAttachmentSource] = []

    func makeController(
        for source: ChatAttachmentSource,
        context: ChatAttachmentFlowContext
    ) -> ChatAttachmentSourceControlling {
        let controller = Task6FakeSourceController(source: source)
        controllers[source] = Task6WeakSourceController(controller)
        createdSources.append(source)
        return controller
    }

    func controller(for source: ChatAttachmentSource) -> Task6FakeSourceController? {
        controllers[source]?.controller
    }
}

private final class Task6WeakSourceController {
    weak var controller: Task6FakeSourceController?

    init(_ controller: Task6FakeSourceController) {
        self.controller = controller
    }
}

private final class Task6FakeSourceController: UIViewController, ChatAttachmentSourceControlling {
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
