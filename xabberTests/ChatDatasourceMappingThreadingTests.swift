import XCTest
import RealmSwift
@testable import xabber

final class ChatDatasourceMappingThreadingTests: XCTestCase {
    private var previousRealmConfiguration: Realm.Configuration!
    private let owner = "owner@example.com"
    private let jid = "juliet@example.com"

    override func setUp() {
        super.setUp()
        previousRealmConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = Realm.Configuration(
            inMemoryIdentifier: "ChatDatasourceMappingThreadingTests-\(name)-\(UUID().uuidString)"
        )
        let realm = try! WRealm.safe()
        try! realm.write {
            realm.deleteAll()
        }
    }

    override func tearDown() {
        Realm.Configuration.defaultConfiguration = previousRealmConfiguration
        previousRealmConfiguration = nil
        super.tearDown()
    }

    func testMappingCanExecuteOffMainWithFrozenRowsAndCapturedContext() throws {
        let controller = makeController()
        let context = controller.captureDatasourceMappingContext()
        let frozen = try seedMessage(primary: "background-message", body: "Mapped off main").freeze()
        let queue = DispatchQueue(label: "ChatDatasourceMappingThreadingTests.mapping")
        let expectation = expectation(description: "background mapping")
        var mappedOnMainThread = true
        var mappedPrimary: String?

        queue.async {
            mappedOnMainThread = Thread.isMainThread
            let result = controller.mapDataset(dataset: [frozen], context: context)
            mappedPrimary = result.datasource.first { $0.primary == "background-message" }?.primary
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 3)
        XCTAssertFalse(mappedOnMainThread)
        XCTAssertEqual(mappedPrimary, "background-message")
    }

    func testStaleMappingGenerationIsCancelledBeforeDatasourceApply() {
        XCTAssertFalse(ChatDatasourceApplyGenerationPolicy.shouldApply(requestGeneration: 1, currentGeneration: 2))
        XCTAssertTrue(ChatDatasourceApplyGenerationPolicy.shouldApply(requestGeneration: 2, currentGeneration: 2))
    }

    func testEditedMessageLayoutInvalidationIsReturnedByMappingResult() throws {
        let controller = makeController()
        let context = controller.captureDatasourceMappingContext()
        let edited = try seedMessage(
            primary: "edited-message",
            body: "Edited body",
            editDate: Date(timeIntervalSince1970: 1_700_000_100)
        ).freeze()

        let result = controller.mapDataset(dataset: [edited], context: context)
        let row = try XCTUnwrap(result.datasource.first { $0.primary == "edited-message" })

        XCTAssertTrue(row.isEdited)
        XCTAssertEqual(result.editedMessagePrimariesNeedingLayoutInvalidation, ["edited-message"])
    }

    func testRepeatedMappingReusesDisplayModelCache() throws {
        let controller = makeController()
        let context = controller.captureDatasourceMappingContext()
        let frozen = try seedMessage(primary: "cached-message", body: "Cache me").freeze()

        _ = controller.mapDataset(dataset: [frozen], context: context)
        let afterFirst = controller.displayModelCache.statistics
        _ = controller.mapDataset(dataset: [frozen], context: context)
        let afterSecond = controller.displayModelCache.statistics

        XCTAssertEqual(afterFirst.misses, 1)
        XCTAssertGreaterThan(afterSecond.hits, afterFirst.hits)
    }

    func testMappingContextInvalidatesDisplayModelsForSearchTraitStyleAndSensitiveRevealChanges() throws {
        let controller = makeController()
        var baseContext = controller.captureDatasourceMappingContext()
        let frozen = try seedMessage(
            primary: "context-message",
            body: "Hello searchable body",
            reference: sensitiveImageReference(primary: "sensitive-image")
        ).freeze()

        let base = controller.mapDataset(dataset: [frozen], context: baseContext)
        let baseRow = try XCTUnwrap(base.datasource.first { $0.primary == "context-message" })
        XCTAssertEqual(controller.displayModelCache.statistics.misses, 1)
        XCTAssertEqual(baseRow.images.first?.isSensitiveRevealed, false)

        var searchContext = baseContext
        searchContext.inSearchMode = true
        searchContext.searchText = "searchable"
        searchContext.displayCacheContext = ChatDisplayModelCacheContext(
            searchText: "searchable",
            localeIdentifier: baseContext.displayCacheContext.localeIdentifier,
            contentSizeCategory: baseContext.displayCacheContext.contentSizeCategory,
            bodyFontName: baseContext.displayCacheContext.bodyFontName,
            bodyFontPointSize: baseContext.displayCacheContext.bodyFontPointSize,
            interfaceStyleRawValue: baseContext.displayCacheContext.interfaceStyleRawValue
        )
        _ = controller.mapDataset(dataset: [frozen], context: searchContext)

        var dynamicTypeContext = baseContext
        dynamicTypeContext.displayCacheContext = ChatDisplayModelCacheContext(
            searchText: nil,
            localeIdentifier: baseContext.displayCacheContext.localeIdentifier,
            contentSizeCategory: "accessibilityLarge",
            bodyFontName: baseContext.displayCacheContext.bodyFontName,
            bodyFontPointSize: baseContext.displayCacheContext.bodyFontPointSize + 4,
            interfaceStyleRawValue: baseContext.displayCacheContext.interfaceStyleRawValue
        )
        _ = controller.mapDataset(dataset: [frozen], context: dynamicTypeContext)

        var darkStyleContext = baseContext
        darkStyleContext.displayCacheContext = ChatDisplayModelCacheContext(
            searchText: nil,
            localeIdentifier: baseContext.displayCacheContext.localeIdentifier,
            contentSizeCategory: baseContext.displayCacheContext.contentSizeCategory,
            bodyFontName: baseContext.displayCacheContext.bodyFontName,
            bodyFontPointSize: baseContext.displayCacheContext.bodyFontPointSize,
            interfaceStyleRawValue: UIUserInterfaceStyle.dark.rawValue
        )
        _ = controller.mapDataset(dataset: [frozen], context: darkStyleContext)

        var revealedContext = baseContext
        revealedContext.revealedSensitiveMediaPrimaries = ["sensitive-image"]
        let revealed = controller.mapDataset(dataset: [frozen], context: revealedContext)
        let revealedRow = try XCTUnwrap(revealed.datasource.first { $0.primary == "context-message" })

        XCTAssertEqual(controller.displayModelCache.statistics.misses, 5)
        XCTAssertEqual(revealedRow.images.first?.isSensitiveRevealed, true)
    }

    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = jid
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: jid, displayName: "Juliet")
        controller.showSkeletonObserver.accept(false)
        controller.inSearchMode.accept(false)
        controller.searchTextObserver.accept(nil)
        return controller
    }

    private func seedMessage(
        primary: String,
        body: String,
        editDate: Date? = nil,
        reference: MessageReferenceStorageItem? = nil
    ) throws -> MessageStorageItem {
        let realm = try WRealm.safe()
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = jid
        message.conversationType = .regular
        message.messageId = "\(primary)-message-id"
        message.archivedId = "\(primary)-archive-id"
        message.body = body
        message.legacyBody = body
        message.date = Date(timeIntervalSince1970: 1_700_000_000)
        message.sentDate = message.date
        message.editDate = editDate
        message.outgoing = false
        message.displayAs = .text
        message.state = .deliver
        message.isRead = false
        if let reference {
            reference.owner = owner
            reference.jid = jid
            reference.messageId = primary
            message.references.append(reference)
        }
        try realm.write {
            realm.add(message, update: .modified)
        }
        return try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: primary))
    }

    private func sensitiveImageReference(primary: String) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.primary = primary
        reference.kind = .media
        reference.mimeType = "image/jpeg"
        reference.metadata = ["media-type": "image/jpeg"]
        reference.downloadUrl = URL(string: "https://files.example.com/image.jpg")
        reference.isSensitive = true
        reference.isSensitiveChecked = true
        return reference
    }
}
