import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentSourceBarTests: XCTestCase {
    func testDefaultSourceBarSelectsGalleryAndHidesGeolocation() throws {
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: Task6FakeSourceControllerFactory()
        )

        sheet.loadViewIfNeeded()

        XCTAssertEqual(sheet.sourceBarView.visibleSources, [.gallery, .file])
        XCTAssertTrue(try XCTUnwrap(sheet.sourceBarView.button(for: .gallery)).isSelected)
        XCTAssertFalse(try XCTUnwrap(sheet.sourceBarView.button(for: .file)).isSelected)
        XCTAssertNil(sheet.sourceBarView.button(for: .geolocation))
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

    func testDisabledSourceIsVisibleButDoesNotRoute() throws {
        let factory = Task6FakeSourceControllerFactory()
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: factory,
            sourceBarConfiguration: ChatAttachmentSourceBarConfiguration(
                sourceAvailability: [
                    .gallery: .available,
                    .file: .disabled,
                    .geolocation: .hidden
                ]
            )
        )
        sheet.loadViewIfNeeded()

        let fileButton = try XCTUnwrap(sheet.sourceBarView.button(for: .file))
        XCTAssertFalse(fileButton.isEnabled)

        fileButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(sheet.activeSource, .gallery)
        XCTAssertEqual(factory.createdSources, [.gallery])
        XCTAssertTrue(try XCTUnwrap(sheet.sourceBarView.button(for: .gallery)).isSelected)
        XCTAssertFalse(fileButton.isSelected)
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
