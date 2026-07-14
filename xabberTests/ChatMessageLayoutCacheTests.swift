import XCTest
@testable import xabber

final class ChatMessageLayoutCacheTests: XCTestCase {
    func testDuplicateLayoutKeyIsMeasuredOnce() {
        let message = makeDatasource(primary: "same", text: "same")
        let counter = ChatMessageLayoutOperationCounter()

        let snapshot = ChatMessageLayoutPrewarmer.prewarm(
            items: [message, message],
            context: context(width: 390),
            reuse: .empty,
            capacity: 32,
            operationCounter: counter,
            measure: measuredFixture
        )

        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(counter.snapshot.measurements, 1)
        XCTAssertEqual(counter.snapshot.misses, 1)
        XCTAssertEqual(counter.snapshot.hits, 1)
    }

    func testUnchangedSecondSnapshotHasOneHundredPercentHits() {
        let items = (0..<1_500).map {
            makeDatasource(primary: "message-\($0)", text: "row \($0)")
        }
        let firstCounter = ChatMessageLayoutOperationCounter()
        let first = ChatMessageLayoutPrewarmer.prewarm(
            items: items,
            context: context(width: 390),
            reuse: .empty,
            capacity: 2_048,
            operationCounter: firstCounter,
            measure: measuredFixture
        )
        let secondCounter = ChatMessageLayoutOperationCounter()
        let second = ChatMessageLayoutPrewarmer.prewarm(
            items: items,
            context: context(width: 390),
            reuse: first,
            capacity: 2_048,
            operationCounter: secondCounter,
            measure: measuredFixture
        )

        XCTAssertEqual(first.count, 1_500)
        XCTAssertEqual(firstCounter.snapshot.measurements, 1_500)
        XCTAssertEqual(second.count, 1_500)
        XCTAssertEqual(secondCounter.snapshot.hits, 1_500)
        XCTAssertEqual(secondCounter.snapshot.misses, 0)
        XCTAssertEqual(secondCounter.snapshot.measurements, 0)
    }

    func testWidthDynamicTypeLocaleStyleAndAvatarModeArePartOfKey() {
        let message = makeDatasource()
        let contexts = [
            context(width: 320),
            context(width: 390),
            context(width: 430),
            context(width: 390, category: "UICTContentSizeCategoryAccessibilityXXXL"),
            context(width: 390, locale: "ar_SA"),
            context(width: 390, style: "smooth"),
            context(width: 390, avatarMode: "top")
        ]

        XCTAssertEqual(Set(contexts.map { ChatMessageLayoutKey(message: message, context: $0) }).count, contexts.count)
    }

    func testReplacementWithSamePrimaryAndNewRevisionDoesNotReuseStaleLayout() {
        let old = makeDatasource(primary: "same", text: "short")
        let edited = makeDatasource(
            primary: "same",
            text: "a much longer edited body that changes wrapping and height",
            editDate: Date(timeIntervalSince1970: 2_000)
        )
        let oldKey = ChatMessageLayoutKey(message: old, context: context(width: 390))
        let editedKey = ChatMessageLayoutKey(message: edited, context: context(width: 390))

        XCTAssertNotEqual(oldKey.revision, editedKey.revision)
        XCTAssertNotEqual(oldKey, editedKey)
    }

    func testExactPrimaryRevisionInvalidationLeavesOtherResidentLayout() throws {
        let first = makeDatasource(primary: "first")
        let second = makeDatasource(primary: "second")
        let snapshot = ChatMessageLayoutPrewarmer.prewarm(
            items: [first, second],
            context: context(width: 390),
            reuse: .empty,
            capacity: 32,
            measure: measuredFixture
        )
        let firstKey = try XCTUnwrap(snapshot.key(forPrimary: "first"))
        let cache = ChatMessageLayoutCache(capacity: 32)
        cache.install(snapshot)

        XCTAssertTrue(cache.invalidate(primary: "first", revision: firstKey.revision))
        XCTAssertNil(cache.layout(forPrimary: "first"))
        XCTAssertNotNil(cache.layout(forPrimary: "second"))
        XCTAssertEqual(cache.count, 1)
    }

    func testMemoryLimitAndWarningCleanupAreDeterministic() {
        let items = (0..<2_500).map { makeDatasource(primary: "message-\($0)") }
        let snapshot = ChatMessageLayoutPrewarmer.prewarm(
            items: items,
            context: context(width: 390),
            reuse: .empty,
            capacity: 2_048,
            measure: measuredFixture
        )
        let cache = ChatMessageLayoutCache(capacity: 2_048)
        cache.install(snapshot)

        XCTAssertEqual(snapshot.count, 2_048)
        XCTAssertEqual(cache.count, 2_048)
        cache.handleMemoryWarning()
        XCTAssertEqual(cache.count, 0)
    }

    func testFifteenHundredMixedRowsPrewarmOffMainWithNoMainMeasurements() {
        let finished = expectation(description: "off-main prewarm")
        let counter = ChatMessageLayoutOperationCounter()
        let items = (0..<1_500).map { index in
            makeDatasource(
                primary: "message-\(index)",
                text: String(repeating: "mixed \(index) ", count: (index % 7) + 1),
                withAvatar: index % 3 == 0
            )
        }
        var result: ChatMessageLayoutSnapshot?

        DispatchQueue(label: "chat-layout-test", qos: .userInitiated).async {
            result = ChatMessageLayoutPrewarmer.prewarm(
                items: items,
                context: self.context(width: 430),
                reuse: .empty,
                capacity: 2_048,
                operationCounter: counter,
                measure: self.measuredFixture
            )
            finished.fulfill()
        }

        wait(for: [finished], timeout: 5)
        XCTAssertEqual(result?.count, 1_500)
        XCTAssertEqual(counter.snapshot.measurements, 1_500)
        XCTAssertEqual(counter.snapshot.mainThreadMeasurements, 0)
    }

    func testProductionCalculatorPrewarmsFifteenHundredRowsAtRequiredWidthsOffMain() {
        let finished = expectation(description: "production layout prewarm")
        let counter = ChatMessageLayoutOperationCounter()
        let items = (0..<1_500).map { index in
            makeDatasource(
                primary: "production-\(index)",
                text: String(repeating: "message \(index) ", count: (index % 9) + 1),
                withAvatar: index % 4 == 0
            )
        }
        var snapshots: [(snapshot: ChatMessageLayoutSnapshot, width: CGFloat)] = []

        DispatchQueue(label: "chat-layout-production-test", qos: .userInitiated).async {
            let contexts = [
                self.context(width: 320),
                self.context(width: 390),
                self.context(width: 430),
                self.context(
                    width: 390,
                    category: "UICTContentSizeCategoryAccessibilityXXXL"
                )
            ]
            snapshots = contexts.map { context in
                (
                    ChatMessageLayoutPrewarmer.prewarm(
                        items: items,
                        context: context,
                        reuse: .empty,
                        capacity: 2_048,
                        operationCounter: counter
                    ),
                    context.width
                )
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 15)
        XCTAssertEqual(snapshots.map { $0.snapshot.count }, [1_500, 1_500, 1_500, 1_500])
        XCTAssertEqual(counter.snapshot.measurements, 6_000)
        XCTAssertEqual(counter.snapshot.mainThreadMeasurements, 0)
        for (snapshot, width) in snapshots {
            XCTAssertEqual(snapshot.layout(forPrimary: "production-1499")?.cellSize.width, width)
            XCTAssertGreaterThan(snapshot.layout(forPrimary: "production-1499")?.cellSize.height ?? 0, 0)
        }
    }

    func testConcurrentPrewarmDoesNotMutateInstalledMainLookupSnapshot() throws {
        let oldItems = (0..<128).map { makeDatasource(primary: "old-\($0)") }
        let oldSnapshot = ChatMessageLayoutPrewarmer.prewarm(
            items: oldItems,
            context: context(width: 390),
            reuse: .empty,
            capacity: 256,
            measure: measuredFixture
        )
        let cache = ChatMessageLayoutCache(capacity: 256)
        cache.install(oldSnapshot)
        let finished = expectation(description: "new snapshot")
        var newSnapshot: ChatMessageLayoutSnapshot?

        DispatchQueue(label: "chat-layout-concurrent").async {
            newSnapshot = ChatMessageLayoutPrewarmer.prewarm(
                items: (0..<128).map { self.makeDatasource(primary: "new-\($0)") },
                context: self.context(width: 430),
                reuse: cache.reuseSnapshot(),
                capacity: 256,
                measure: self.measuredFixture
            )
            finished.fulfill()
        }

        for index in 0..<128 {
            XCTAssertNotNil(cache.layout(forPrimary: "old-\(index)"))
        }
        wait(for: [finished], timeout: 5)
        cache.install(try XCTUnwrap(newSnapshot))
        XCTAssertNil(cache.layout(forPrimary: "old-0"))
        XCTAssertNotNil(cache.layout(forPrimary: "new-127"))
    }

    private func context(
        width: CGFloat,
        category: String = "UICTContentSizeCategoryL",
        locale: String = "en_US",
        style: String = "no_tail",
        avatarMode: String = "bottom"
    ) -> ChatMessageLayoutContext {
        ChatMessageLayoutContext(
            width: width,
            contentSizeCategory: category,
            localeIdentifier: locale,
            interfaceStyleRawValue: UIUserInterfaceStyle.light.rawValue,
            messageStyle: style,
            cornerRadius: "16",
            avatarMode: avatarMode
        )
    }

    private func measuredFixture(
        message: ChatViewController.Datasource,
        context: ChatMessageLayoutContext
    ) -> ChatMessageLayout {
        ChatMessageLayout.empty(
            cellSize: CGSize(
                width: context.width,
                height: 40 + CGFloat(message.kind.textLength % 80)
            )
        )
    }

    private func makeDatasource(
        primary: String = "message-1",
        text: String = "Hello",
        editDate: Date? = nil,
        withAvatar: Bool = false
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: "romeo@example.com",
            owner: "owner@example.com",
            outgoing: false,
            sender: Sender(id: "romeo@example.com", displayName: "Romeo"),
            messageId: "\(primary)-message-id",
            sentDate: Date(timeIntervalSince1970: 1_700_000_000),
            editDate: editDate,
            kind: .attributedText(NSAttributedString(
                string: text,
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body)]
            )),
            withAuthor: false,
            withAvatar: withAvatar,
            reservesAvatarSpace: withAvatar,
            error: false,
            errorType: "",
            canPinMessage: true,
            canEditMessage: true,
            canDeleteMessage: true,
            forwards: [],
            isOutgoing: false,
            isEdited: editDate != nil,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .deliver,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "\(primary)-archived",
            queryIds: nil,
            isRead: false,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            isFakeMessage: false,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .none,
            avatarUrl: nil,
            attributedAuthor: nil
        )
    }
}

private extension MessageKind {
    var textLength: Int {
        switch self {
        case .attributedText(let text), .system(let text), .initial(let text),
                .skeleton(let text), .date(let text), .unread(let text):
            return text.length
        case .emoji(let text):
            return text.count
        case .sticker, .call:
            return 1
        }
    }
}
