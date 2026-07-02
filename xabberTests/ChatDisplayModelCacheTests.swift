import XCTest
@testable import xabber

final class ChatDisplayModelCacheTests: XCTestCase {
    func testRepeatedMappingUnchangedMessageReusesCachedDisplayModel() {
        let cache = ChatDisplayModelCache(capacity: 8)
        let key = makeKey(revision: "body-v1")
        var buildCount = 0

        let first = cache.model(for: key) {
            buildCount += 1
            return makeModel(body: "Hello")
        }
        let second = cache.model(for: key) {
            buildCount += 1
            return makeModel(body: "Should not be rebuilt")
        }

        XCTAssertTrue(first === second)
        XCTAssertEqual(second.bodyText, "Hello")
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(cache.statistics.hits, 1)
        XCTAssertEqual(cache.statistics.misses, 1)
    }

    func testMessageEditInvalidatesCachedBody() {
        let cache = ChatDisplayModelCache(capacity: 8)
        var buildCount = 0

        let original = cache.model(for: makeKey(revision: "body-v1")) {
            buildCount += 1
            return makeModel(body: "Original")
        }
        let edited = cache.model(for: makeKey(revision: "body-v2-edit-date-100")) {
            buildCount += 1
            return makeModel(body: "Edited")
        }

        XCTAssertFalse(original === edited)
        XCTAssertEqual(original.bodyText, "Original")
        XCTAssertEqual(edited.bodyText, "Edited")
        XCTAssertEqual(buildCount, 2)
    }

    func testDisplayContextInvalidatesAttributedTextCache() {
        let cache = ChatDisplayModelCache(capacity: 8)
        var buildCount = 0
        let compactContext = ChatDisplayModelCacheContext(
            searchText: nil,
            localeIdentifier: "en_US",
            contentSizeCategory: "medium",
            bodyFontName: "body",
            bodyFontPointSize: 17,
            interfaceStyleRawValue: 1
        )
        let largerFontContext = ChatDisplayModelCacheContext(
            searchText: nil,
            localeIdentifier: "en_US",
            contentSizeCategory: "accessibilityLarge",
            bodyFontName: "body",
            bodyFontPointSize: 23,
            interfaceStyleRawValue: 1
        )

        _ = cache.model(for: makeKey(revision: "body-v1", context: compactContext)) {
            buildCount += 1
            return makeModel(body: "Hello", fontSize: 17)
        }
        let rebuilt = cache.model(for: makeKey(revision: "body-v1", context: largerFontContext)) {
            buildCount += 1
            return makeModel(body: "Hello", fontSize: 23)
        }

        XCTAssertEqual(buildCount, 2)
        XCTAssertEqual(rebuilt.bodyFontPointSize, 23)
    }

    func testLazyForwardMappingEventuallyProducesEagerModel() {
        let eager = [makeForward(primary: "forward-1", text: "Forward body")]
        var buildCount = 0
        let lazy = ChatLazyForwardDisplayModel(signature: "forward-v1") {
            buildCount += 1
            return eager
        }

        XCTAssertFalse(lazy.isResolved)
        XCTAssertEqual(buildCount, 0)

        XCTAssertEqual(lazy.attachments.map(\.primary), eager.map(\.primary))
        XCTAssertEqual(lazy.attachments.first?.textMessage?.string, eager.first?.textMessage?.string)
        XCTAssertTrue(lazy.isResolved)
        XCTAssertEqual(buildCount, 1)

        _ = lazy.attachments
        XCTAssertEqual(buildCount, 1)
    }

    private func makeKey(
        primary: String = "message-1",
        revision: String,
        context: ChatDisplayModelCacheContext = ChatDisplayModelCacheContext(
            searchText: nil,
            localeIdentifier: "en_US",
            contentSizeCategory: "medium",
            bodyFontName: "body",
            bodyFontPointSize: 17,
            interfaceStyleRawValue: 1
        )
    ) -> ChatDisplayModelCacheKey {
        ChatDisplayModelCacheKey(
            messagePrimary: primary,
            displayRevision: revision,
            context: context
        )
    }

    private func makeModel(body: String, fontSize: CGFloat = 17) -> ChatCachedDisplayModel {
        ChatCachedDisplayModel(
            kind: .attributedText(NSAttributedString(
                string: body,
                attributes: [.font: UIFont.systemFont(ofSize: fontSize)]
            )),
            mappedReferences: .empty,
            lazyForwards: .eager([]),
            isDownloaded: true,
            timeMarkerText: NSAttributedString(string: "12:00")
        )
    }

    private func makeForward(primary: String, text: String) -> MessageAttachment {
        MessageAttachment(
            primary: primary,
            author: "Juliet",
            jid: "juliet@example.com",
            outgoing: false,
            textMessage: NSAttributedString(string: text),
            images: [],
            videos: [],
            locations: [],
            contacts: [],
            files: [],
            audios: [],
            timeMarker: NSAttributedString(string: "12:01"),
            subforwards: []
        )
    }
}
