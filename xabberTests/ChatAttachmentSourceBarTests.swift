import XCTest
import UIKit
@testable import xabber

@MainActor
final class ChatAttachmentSourceBarTests: XCTestCase {
    func testDefaultSourceBarSelectsGalleryAndShowsContactAvailable() throws {
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
        XCTAssertTrue(locationButton.isEnabled)
        XCTAssertTrue(contactButton.isEnabled)
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

    func testLocationAndContactSourcesAreAvailableAndRoute() throws {
        let factory = Task6FakeSourceControllerFactory()
        let sheet = ChatAttachmentSheetViewController(
            context: Self.makeContext(),
            sourceControllerFactory: factory
        )
        sheet.loadViewIfNeeded()

        let locationButton = try XCTUnwrap(sheet.sourceBarView.button(for: .geolocation))
        let contactButton = try XCTUnwrap(sheet.sourceBarView.button(for: .contact))
        XCTAssertTrue(locationButton.isEnabled)
        XCTAssertTrue(contactButton.isEnabled)

        locationButton.sendActions(for: .touchUpInside)
        contactButton.sendActions(for: .touchUpInside)

        XCTAssertEqual(sheet.activeSource, .contact)
        XCTAssertEqual(factory.createdSources, [.gallery, .geolocation, .contact])
        XCTAssertFalse(try XCTUnwrap(sheet.sourceBarView.button(for: .gallery)).isSelected)
        XCTAssertFalse(locationButton.isSelected)
        XCTAssertTrue(contactButton.isSelected)
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

final class ChatAttachmentContactSourceTests: XCTestCase {
    func testContactSourceDataSourceFiltersCurrentOwnerMutualRosterContacts() {
        let records = [
            makeRecord(jid: "alice@example.com", title: "Alice"),
            makeRecord(owner: "other@example.com", jid: "other-contact@example.com", title: "Other Owner"),
            makeRecord(jid: "hidden@example.com", title: "Hidden", isHidden: true),
            makeRecord(jid: "removed@example.com", title: "Removed", removed: true),
            makeRecord(jid: "not-contact@example.com", title: "Room", isContact: false),
            makeRecord(jid: "resource-room@example.com", title: "Room Resource", isContactEntity: false),
            makeRecord(jid: "pending@example.com", title: "Pending", subscription: .to),
            makeRecord(jid: "owner@example.com", title: "Self")
        ]

        let items = ChatAttachmentContactSourceDataSource.items(
            from: records,
            owner: "owner@example.com",
            searchQuery: ""
        )

        XCTAssertEqual(items.map(\.jid), ["alice@example.com"])
        XCTAssertEqual(items.first?.displayTitle, "Alice")
    }

    func testContactSourceDataSourceSearchesDisplayTitleAndJID() {
        let records = [
            makeRecord(jid: "alice@example.com", title: "Alice Capulet"),
            makeRecord(jid: "bob@example.com", title: "Robert")
        ]

        let titleMatches = ChatAttachmentContactSourceDataSource.items(
            from: records,
            owner: "owner@example.com",
            searchQuery: "cap"
        )
        let jidMatches = ChatAttachmentContactSourceDataSource.items(
            from: records,
            owner: "owner@example.com",
            searchQuery: "bob@"
        )

        XCTAssertEqual(titleMatches.map(\.jid), ["alice@example.com"])
        XCTAssertEqual(jidMatches.map(\.jid), ["bob@example.com"])
    }

    @MainActor
    func testSelectingContactEmitsPreparedContactDraft() throws {
        let item = ChatAttachmentContactListItem(
            owner: "owner@example.com",
            jid: "alice@example.com",
            displayTitle: "Alice Capulet",
            nickname: "Ally",
            given: "Alice",
            family: "Capulet",
            avatarURL: "https://cdn.example.com/alice.png",
            avatarMetadata: ["avatar_id": "hash-1"]
        )
        let dataSource = StaticContactSourceDataSource(items: [item])
        let controller = ChatAttachmentContactSourceViewController(
            owner: "owner@example.com",
            dataSource: dataSource
        )
        var selectionCounts: [Int] = []
        var selectedDrafts: [[AttachmentDraft]] = []
        controller.onSelectionCountChanged = { selectionCounts.append($0) }
        controller.onSelectedAttachmentDraftsChanged = { selectedDrafts.append($0) }

        controller.loadViewIfNeeded()
        controller.selectContact(item)

        XCTAssertEqual(selectionCounts, [1])
        let draft = try XCTUnwrap(selectedDrafts.last?.first)
        XCTAssertEqual(draft.source, .contact)
        XCTAssertEqual(draft.mediaKind, .contact)
        XCTAssertFalse(draft.requiresUpload)
        let contact = try XCTUnwrap(draft.preparedContact)
        XCTAssertEqual(contact.jid, "alice@example.com")
        XCTAssertEqual(contact.nickname, "Ally")
        XCTAssertEqual(contact.given, "Alice")
        XCTAssertEqual(contact.family, "Capulet")
        XCTAssertEqual(contact.displayTitle, "Alice Capulet")
        XCTAssertEqual(contact.avatarURL, "https://cdn.example.com/alice.png")
        XCTAssertEqual(contact.avatarMetadata["avatar_id"], "hash-1")
    }

    private func makeRecord(
        owner: String = "owner@example.com",
        jid: String,
        title: String,
        nickname: String? = nil,
        given: String? = nil,
        family: String? = nil,
        avatarURL: String? = nil,
        isHidden: Bool = false,
        removed: Bool = false,
        isContact: Bool = true,
        subscription: RosterStorageItem.Subsccribtion = .both,
        isContactEntity: Bool = true
    ) -> ChatAttachmentContactRosterRecord {
        ChatAttachmentContactRosterRecord(
            owner: owner,
            jid: jid,
            displayTitle: title,
            nickname: nickname,
            given: given,
            family: family,
            avatarURL: avatarURL,
            isHidden: isHidden,
            removed: removed,
            isContact: isContact,
            subscription: subscription,
            isContactEntity: isContactEntity
        )
    }
}

private final class StaticContactSourceDataSource: ChatAttachmentContactSourceDataProviding {
    private let items: [ChatAttachmentContactListItem]

    init(items: [ChatAttachmentContactListItem]) {
        self.items = items
    }

    func loadItems(owner: String, searchQuery: String) -> [ChatAttachmentContactListItem] {
        ChatAttachmentContactSourceDataSource.filteredItems(
            items,
            searchQuery: searchQuery
        )
    }
}
