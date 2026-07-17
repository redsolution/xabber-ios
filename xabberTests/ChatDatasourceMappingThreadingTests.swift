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

    func testPrelayoutMappingUsesViewWidthAndKeepsTimestampInsidePreparedGeometry() throws {
        let controller = makeController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.messagesCollectionView.frame = .zero
        let flowLayout = try XCTUnwrap(
            controller.messagesCollectionView.collectionViewLayout as? MessagesCollectionViewFlowLayout
        )
        XCTAssertEqual(flowLayout.itemWidth, 0)

        let context = controller.captureDatasourceMappingContext()

        XCTAssertEqual(context.layoutContext.width, 390)
        let message = try seedMessage(
            primary: "prelayout-message",
            body: "Local message before the collection has its first layout"
        ).freeze()
        let result = controller.mapDataset(dataset: [message], context: context)
        let layout = try XCTUnwrap(result.layoutSnapshot.layout(forPrimary: message.primary))
        let timeFrame = CGRect(
            x: layout.messageContainerSize.width - layout.timeMarkerSize.width -
                layout.timeMarkerInsets.right - layout.tailWidth -
                layout.messageContainerPadding.right - layout.messageContainerMargin.right,
            y: layout.messageContainerSize.height - layout.timeMarkerSize.height -
                layout.timeMarkerInsets.bottom - layout.messageContainerPadding.bottom -
                layout.messageContainerMargin.bottom - 2,
            width: layout.timeMarkerSize.width,
            height: layout.timeMarkerSize.height
        )

        XCTAssertTrue(
            ChatMessageFrameGeometryValidator.violations(
                frames: [.init(name: "time", frame: timeFrame)],
                containerBounds: CGRect(origin: .zero, size: layout.messageContainerSize)
            ).isEmpty
        )
    }

    func testStaleMappingGenerationIsCancelledBeforeDatasourceApply() {
        XCTAssertFalse(ChatDatasourceApplyGenerationPolicy.shouldApply(requestGeneration: 1, currentGeneration: 2))
        XCTAssertTrue(ChatDatasourceApplyGenerationPolicy.shouldApply(requestGeneration: 2, currentGeneration: 2))
    }

    func testMapDatasetCooperativelyStopsAnObsoleteTokenWithinOneBatch() throws {
        let controller = makeController()
        let context = controller.captureDatasourceMappingContext()
        let rows = try seedMessages(count: 64)
        let coordinator = ChatDatasetMappingJobCoordinator(cancellationCheckInterval: 16)
        let obsolete = coordinator.begin(generation: 1)
        for _ in 0..<7 {
            XCTAssertTrue(obsolete.shouldProcessNextRow())
        }
        _ = coordinator.begin(generation: 2)

        let result = controller.mapDataset(
            dataset: rows,
            context: context,
            cancellationToken: obsolete
        )

        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThanOrEqual(obsolete.statistics.rowsProcessedAfterCancellation, 16)
        XCTAssertLessThan(result.datasource.filter { !$0.isFakeMessage }.count, rows.count)
        XCTAssertEqual(result.layoutSnapshot.count, context.layoutReuseSnapshot.count)
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

    func testRepeatedMappingOfFifteenHundredRowsKeepsAtLeastNinetyFivePercentRichHits() throws {
        let controller = makeController()
        let context = controller.captureDatasourceMappingContext()
        let frozen = try seedMessages(count: 1_500)

        _ = controller.mapDataset(dataset: frozen, context: context)
        let afterFirst = controller.displayModelCache.statistics
        _ = controller.mapDataset(dataset: frozen, context: context)
        let afterSecond = controller.displayModelCache.statistics

        let secondPassHits = afterSecond.hits - afterFirst.hits
        let secondPassMisses = afterSecond.misses - afterFirst.misses
        XCTAssertGreaterThanOrEqual(Double(secondPassHits) / 1_500.0, 0.95)
        XCTAssertEqual(secondPassMisses, 0)
        XCTAssertEqual(afterSecond.entryCount, 1_500)
        XCTAssertEqual(afterSecond.linearRecencyScanSteps, 0)
    }

    func testReceiptOnlyMutationReusesRichModelAndRefreshesChrome() throws {
        let controller = makeController()
        let context = controller.captureDatasourceMappingContext()
        let message = try seedMessage(primary: "receipt-cache", body: "Stable body")
        let first = controller.mapDataset(dataset: [message.freeze()], context: context)
        let firstRow = try XCTUnwrap(first.datasource.first { $0.primary == message.primary })
        let afterFirst = controller.displayModelCache.statistics

        let realm = try WRealm.safe()
        try realm.write {
            message.state = .read
            message.isRead = true
            message.messageError = "updated chrome"
            message.errorMetadata = ["receipt": true]
        }
        let second = controller.mapDataset(dataset: [message.freeze()], context: context)
        let secondRow = try XCTUnwrap(second.datasource.first { $0.primary == message.primary })
        let afterSecond = controller.displayModelCache.statistics

        XCTAssertEqual(afterSecond.misses, afterFirst.misses)
        XCTAssertEqual(afterSecond.hits - afterFirst.hits, 1)
        XCTAssertEqual(messageText(firstRow.kind), messageText(secondRow.kind))
        XCTAssertEqual(secondRow.state, .read)
        XCTAssertTrue(secondRow.isRead)
        XCTAssertEqual(secondRow.errorMetadata?["receipt"] as? Bool, true)
    }

    func testRevealOneSensitiveReferenceInvalidatesOnlyItsOwningRichModel() throws {
        let controller = makeController()
        let baseContext = controller.captureDatasourceMappingContext()
        let first = try seedMessage(
            primary: "reveal-first",
            body: "First",
            reference: sensitiveImageReference(primary: "reveal-first-media")
        )
        let second = try seedMessage(
            primary: "reveal-second",
            body: "Second",
            reference: sensitiveImageReference(primary: "reveal-second-media")
        )
        let rows = [first.freeze(), second.freeze()]
        _ = controller.mapDataset(dataset: rows, context: baseContext)
        let beforeReveal = controller.displayModelCache.statistics

        var revealedContext = baseContext
        revealedContext.revealedSensitiveMediaPrimaries = ["reveal-first-media"]
        let revealed = controller.mapDataset(dataset: rows, context: revealedContext)
        let afterReveal = controller.displayModelCache.statistics

        XCTAssertEqual(afterReveal.misses - beforeReveal.misses, 1)
        XCTAssertEqual(afterReveal.hits - beforeReveal.hits, 1)
        XCTAssertEqual(
            revealed.datasource.first { $0.primary == "reveal-first" }?.images.first?.isSensitiveRevealed,
            true
        )
        XCTAssertEqual(
            revealed.datasource.first { $0.primary == "reveal-second" }?.images.first?.isSensitiveRevealed,
            false
        )
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

    func testDisplaySnapshotFreezesReferenceAndForwardValuesAwayFromRealmMutations() throws {
        let message = try seedMessage(
            primary: "snapshot-message",
            body: "Snapshot body",
            reference: imageReference(primary: "snapshot-image", url: "https://files.example.com/original.jpg", width: 120, height: 80)
        )
        let forward = makeForward(primary: "snapshot-forward", body: "Original forward")
        let realm = try WRealm.safe()
        try realm.write {
            message.inlineForwards.append(forward)
        }
        let presentation = SavedMessageDisplayPolicy.presentation(
            for: message,
            currentUserJid: owner,
            currentUserName: "Owner"
        )

        let snapshot = ChatMessageDisplaySnapshot(item: message, presentation: presentation)

        try realm.write {
            message.body = "Edited body"
            message.references.first?.url = "https://files.example.com/edited.jpg"
            message.references.first?.metadata = [
                "media-type": "image/jpeg",
                "width": 300,
                "height": 180
            ]
            message.inlineForwards.first?.body = "Edited forward"
        }

        XCTAssertEqual(snapshot.body, "Snapshot body")
        XCTAssertEqual(snapshot.presentation.visibleBody, "Snapshot body")
        XCTAssertEqual(snapshot.presentation.visibleReferences.first?.downloadUrl?.absoluteString, "https://files.example.com/original.jpg")
        XCTAssertEqual(snapshot.presentation.visibleReferences.first?.sizeInPx, CGSize(width: 120, height: 80))
        XCTAssertEqual(snapshot.presentation.visibleForwards.first?.body, "Original forward")
    }

    func testDisplaySnapshotRevisionTracksReferenceForwardAndRevealInputs() throws {
        let message = try seedMessage(
            primary: "revision-message",
            body: "Revision body",
            reference: imageReference(primary: "revision-image", url: "https://files.example.com/original.jpg", width: 120, height: 80)
        )
        let forward = makeForward(primary: "revision-forward", body: "Original forward")
        let realm = try WRealm.safe()
        try realm.write {
            message.inlineForwards.append(forward)
        }
        let originalPresentation = SavedMessageDisplayPolicy.presentation(
            for: message,
            currentUserJid: owner,
            currentUserName: "Owner"
        )
        let original = ChatMessageDisplaySnapshot(item: message, presentation: originalPresentation)
        let originalRevision = ChatMessageRichStorageRevision.capture(
            message,
            revealedSensitiveMediaPrimaries: []
        )
        let revealedRevision = ChatMessageRichStorageRevision.capture(
            message,
            revealedSensitiveMediaPrimaries: ["revision-image"]
        )

        try realm.write {
            message.references.first?.url = "https://files.example.com/edited.jpg"
            message.inlineForwards.first?.body = "Edited forward"
        }
        let editedPresentation = SavedMessageDisplayPolicy.presentation(
            for: message,
            currentUserJid: owner,
            currentUserName: "Owner"
        )
        let edited = ChatMessageDisplaySnapshot(item: message, presentation: editedPresentation)
        let editedRevision = ChatMessageRichStorageRevision.capture(
            message,
            revealedSensitiveMediaPrimaries: []
        )

        XCTAssertNotEqual(original.presentation.visibleReferencesRevision, edited.presentation.visibleReferencesRevision)
        XCTAssertNotEqual(original.presentation.visibleForwardsRevision, edited.presentation.visibleForwardsRevision)
        XCTAssertNotEqual(originalRevision, revealedRevision)
        XCTAssertNotEqual(originalRevision, editedRevision)
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

    private func messageText(_ kind: MessageKind) -> String? {
        switch kind {
        case .attributedText(let text), .system(let text):
            return text.string
        default:
            return nil
        }
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

    private func seedMessages(count: Int) throws -> [MessageStorageItem] {
        let realm = try WRealm.safe()
        try realm.write {
            for index in 0..<count {
                let primary = "bulk-\(index)"
                let message = MessageStorageItem()
                message.primary = primary
                message.owner = owner
                message.opponent = jid
                message.conversationType = .regular
                message.messageId = "\(primary)-message-id"
                message.archivedId = "\(primary)-archive-id"
                message.body = "Bulk body \(index)"
                message.legacyBody = message.body
                message.date = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                message.sentDate = message.date
                message.outgoing = index.isMultiple(of: 3)
                message.displayAs = .text
                message.state = .deliver
                realm.add(message, update: .modified)
            }
        }
        return (0..<count).compactMap { index in
            realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "bulk-\(index)")?.freeze()
        }
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

    private func imageReference(
        primary: String,
        url: String,
        width: Int,
        height: Int
    ) -> MessageReferenceStorageItem {
        let reference = MessageReferenceStorageItem()
        reference.primary = primary
        reference.kind = .media
        reference.mimeType = "image/jpeg"
        reference.metadata = [
            "media-type": "image/jpeg",
            "width": width,
            "height": height
        ]
        reference.url = url
        return reference
    }

    private func makeForward(primary: String, body: String) -> MessageForwardsInlineStorageItem {
        let forward = MessageForwardsInlineStorageItem()
        forward.primary = primary
        forward.messageId = "\(primary)-message-id"
        forward.owner = owner
        forward.opponent = jid
        forward.jid = jid
        forward.parentId = "parent-\(primary)"
        forward.body = body
        forward.forwardJid = jid
        forward.forwardNickname = "Juliet"
        forward.isOutgoing = false
        forward.originalDate = Date(timeIntervalSince1970: 1_700_000_050)
        return forward
    }
}
