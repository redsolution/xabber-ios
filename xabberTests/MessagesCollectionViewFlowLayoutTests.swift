import XCTest
@testable import xabber

final class MessagesCollectionViewFlowLayoutTests: XCTestCase {
    func testImmutableLayoutAppliesCellSizeAndEveryCustomAttribute() {
        var layout = ChatMessageLayout.empty(cellSize: CGSize(width: 390, height: 180))
        layout.messagePrimary = "message"
        layout.avatarSize = CGSize(width: 32, height: 32)
        layout.avatarPosition = AvatarPosition(horizontal: .cellLeading, vertical: .messageTop)
        layout.side = .left
        layout.messageContainerSize = CGSize(width: 280, height: 164)
        layout.messageContainerMargin = UIEdgeInsets(top: 1, left: 2, bottom: 3, right: 4)
        layout.messageContainerPadding = UIEdgeInsets(top: 5, left: 6, bottom: 7, right: 8)
        layout.messageLabelInsets = UIEdgeInsets(top: 9, left: 10, bottom: 11, right: 12)
        layout.forwardsContainerViewSize = CGSize(width: 200, height: 90)
        layout.forwardsInlineViewSize = [forwardSize]
        layout.audioInlineViewSize = CGSize(width: 100, height: 44)
        layout.imagesInlineViewSize = CGSize(width: 220, height: 220)
        layout.videosInlineViewSize = CGSize(width: 210, height: 180)
        layout.locationsInlineViewSize = CGSize(width: 200, height: 200)
        layout.contactsInlineViewSize = CGSize(width: 190, height: 44)
        layout.filesInlineViewSize = CGSize(width: 180, height: 44)
        layout.textInlineViewSize = CGSize(width: 160, height: 48)
        layout.warningInlineViewSize = CGSize(width: 140, height: 30)
        layout.authorInlineSize = CGSize(width: 120, height: 18)
        layout.tail = "smooth"
        layout.cornerRadius = "12"
        layout.tailWidth = 8
        layout.timeMarkerSize = CGSize(width: 42, height: 14)
        layout.timeMarkerIndicator = .read
        layout.timeMarkerRadius = 7
        layout.timeMarkerInsets = UIEdgeInsets(top: 2, left: 3, bottom: 4, right: 5)
        layout.timeMarkerWithBackplate = true
        layout.inlineContainerSizeInsets = UIEdgeInsets(top: 3, left: 4, bottom: 5, right: 6)
        layout.inlineContainerSizePadding = UIEdgeInsets(top: 7, left: 8, bottom: 9, right: 10)
        layout.isImageMessage = true

        let attributes = MessagesCollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        layout.apply(to: attributes)

        XCTAssertEqual(attributes.size, layout.cellSize)
        XCTAssertEqual(ChatMessageLayout(attributes: attributes), layout)
    }

    func testSizeAndAttributesUseSameReadyLayoutValue() {
        var layout = ChatMessageLayout.empty(cellSize: CGSize(width: 430, height: 212))
        layout.messageContainerSize = CGSize(width: 300, height: 196)
        let cache = ChatMessageLayoutCache(capacity: 8)
        let key = ChatMessageLayoutKey(
            primary: "message",
            revision: "revision",
            context: ChatMessageLayoutContext(
                width: 430,
                contentSizeCategory: "UICTContentSizeCategoryL",
                localeIdentifier: "en_US",
                interfaceStyleRawValue: 1,
                messageStyle: "no_tail",
                cornerRadius: "16",
                avatarMode: "bottom"
            )
        )
        cache.install(ChatMessageLayoutSnapshot.single(key: key, layout: layout))

        let ready = cache.layout(forPrimary: "message")
        let attributes = MessagesCollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: 0, section: 0)
        )
        ready?.apply(to: attributes)

        XCTAssertEqual(ready?.cellSize, CGSize(width: 430, height: 212))
        XCTAssertEqual(attributes.size, ready?.cellSize)
        XCTAssertEqual(attributes.messageContainerSize, ready?.messageContainerSize)
    }

    func testFlowCallbacksOnlyReadReadyCacheAndDoNotInvokeCalculators() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/chat/messages_kit/Layout/MessagesCollectionViewFlowLayout.swift"
            ),
            encoding: .utf8
        )
        for function in ["layoutAttributesForElements", "layoutAttributesForItem", "sizeForItem"] {
            let body = try XCTUnwrap(functionBody(named: function, in: source))
            XCTAssertTrue(body.contains("readyLayout(for:"), "\(function) is not an O(1) ready-layout read")
            XCTAssertFalse(body.contains("cellSizeCalculator"), "\(function) performs synchronous calculation")
            XCTAssertFalse(body.contains("sizeForItem(at:"), "\(function) recursively measures")
            XCTAssertFalse(body.contains("configure(attributes:"), "\(function) configures by recalculation")
        }
        let readyBody = try XCTUnwrap(functionBody(named: "readyLayout", in: source))
        XCTAssertTrue(readyBody.contains("cache.layout(forPrimary:"))
        XCTAssertTrue(readyBody.contains("ChatMessageLayout.fallback"))
        XCTAssertFalse(readyBody.contains("boundingRect"))
        XCTAssertFalse(readyBody.contains("ChatMessageLayoutCalculator"))
    }

    func testFlowCallbacksCopySuperclassAttributesBeforeMutation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/chat/messages_kit/Layout/MessagesCollectionViewFlowLayout.swift"
            ),
            encoding: .utf8
        )

        for function in [
            "layoutAttributesForElements",
            "layoutAttributesForItem",
            "layoutAttributesForSupplementaryView"
        ] {
            let body = try XCTUnwrap(functionBody(named: function, in: source))
            let superclassRead = try XCTUnwrap(body.range(of: "super."))
            let copy = try XCTUnwrap(body.range(of: ".copy()"))

            XCTAssertLessThan(
                superclassRead.lowerBound,
                copy.lowerBound,
                "\(function) must copy UIKit-owned cached attributes before applying chat layout"
            )
        }
    }

    func testDatasourceApplyInstallsPreparedLayoutsBeforeUIKitMutation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "xabber/controllers/chats/chat/extension/ChatViewController+Dataset.swift"
            ),
            encoding: .utf8
        )
        let body = try XCTUnwrap(functionBody(named: "applyChatDatasource", in: source))
        let atomicStart = try XCTUnwrap(
            body.range(of: "runAtomicInitialFrameVisualCommit {")
        )
        let standardMarker =
            "\n        if let preparedLayouts {\n" +
            "            flowLayout?.cache.install(preparedLayouts)\n" +
            "        }\n\n" +
            "        switch mode {"
        let tail = String(body[atomicStart.lowerBound...])
        let standardStart = try XCTUnwrap(tail.range(of: standardMarker))
        let atomicPath = String(tail[..<standardStart.lowerBound])
        let standardPath = String(tail[standardStart.lowerBound...])
        let atomicInstall = try XCTUnwrap(
            atomicPath.range(of: "cache.install(preparedLayouts)")
        )
        let atomicDatasource = try XCTUnwrap(
            atomicPath.range(of: "self.datasource = items")
        )
        let atomicReload = try XCTUnwrap(atomicPath.range(of: "reloadData()"))
        let atomicFinish = try XCTUnwrap(atomicPath.range(of: "finish()"))
        XCTAssertLessThan(atomicInstall.lowerBound, atomicDatasource.lowerBound)
        XCTAssertLessThan(atomicDatasource.lowerBound, atomicReload.lowerBound)
        XCTAssertLessThan(atomicReload.lowerBound, atomicFinish.lowerBound)

        let standardInstall = try XCTUnwrap(
            standardPath.range(of: "cache.install(preparedLayouts)")
        )
        let standardReload = try XCTUnwrap(standardPath.range(of: "reloadData()"))
        XCTAssertLessThan(standardInstall.lowerBound, standardReload.lowerBound)
        XCTAssertFalse(body.contains("oldSizeProvider: { flowLayout?.sizeForMessage"))
        XCTAssertFalse(body.contains("newSizeProvider: { flowLayout?.sizeForMessage"))
    }

    func testEveryWorkerMappingApplyCarriesItsPreparedLayoutSnapshot() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workerSourcePaths = [
            "xabber/controllers/chats/chat/ChatViewController.swift",
            "xabber/controllers/chats/chat/extension/ChatViewController+ArchiveEngine.swift",
            "xabber/controllers/chats/chat/extension/ChatViewController+SearchBar.swift"
        ]
        let mappingMarker = "let mappingResult = self.mapDataset("
        let preparedApplyMarker =
            "preparedLayouts: mappingResult.layoutSnapshot"
        var inspectedMappingSiteCount = 0

        for sourcePath in workerSourcePaths {
            let source = try String(
                contentsOf: root.appendingPathComponent(sourcePath),
                encoding: .utf8
            )
            let mappingTails = source
                .components(separatedBy: mappingMarker)
                .dropFirst()
            XCTAssertFalse(
                mappingTails.isEmpty,
                "Expected at least one worker mapping site in \(sourcePath)"
            )
            for (index, mappingTail) in mappingTails.enumerated() {
                inspectedMappingSiteCount += 1
                XCTAssertTrue(
                    mappingTail.contains(preparedApplyMarker),
                    "Worker mapping site \(index + 1) in \(sourcePath) must carry its prepared layout snapshot into datasource apply"
                )
            }
        }

        XCTAssertGreaterThan(inspectedMappingSiteCount, 0)
    }

    private var forwardSize: MessageAttachmentSizes {
        MessageAttachmentSizes(
            textLabelSize: CGSize(width: 120, height: 30),
            imagesContainerSize: .zero,
            videosContainerSize: .zero,
            locationsContainerSize: .zero,
            contactsContainerSize: .zero,
            filesContainerSize: .zero,
            audiosContainerSize: .zero,
            containerSize: CGSize(width: 180, height: 70),
            authorSize: CGSize(width: 90, height: 18),
            messageContainer: CGSize(width: 192, height: 80),
            timeMarker: CGSize(width: 36, height: 14)
        )
    }

    private func functionBody(named name: String, in source: String) -> String? {
        guard let nameRange = source.range(of: "func \(name)") else { return nil }
        guard let openBrace = source[nameRange.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = openBrace
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[openBrace...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
