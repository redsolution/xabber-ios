import XCTest
@testable import xabber

final class ChatDiffKeySignatureTests: XCTestCase {
    func testIdenticalMessagesProduceIdenticalContentSignatures() {
        let first = makeDatasource(text: "Hello", audios: [makeAudio(primary: "voice-1")])
        let second = makeDatasource(text: "Hello", audios: [makeAudio(primary: "voice-1")])

        XCTAssertEqual(
            ChatMessageUpdatePolicy.contentSignature(for: first),
            ChatMessageUpdatePolicy.contentSignature(for: second)
        )
    }

    func testDisplayRelevantFieldsChangeContentSignature() throws {
        let original = makeDatasource(
            text: "Hello",
            images: [
                ImageAttachment(
                    primary: "image-1",
                    url: try XCTUnwrap(URL(string: "https://files.example.com/old.jpg")),
                    size: CGSize(width: 100, height: 80)
                )
            ]
        )
        let changedText = makeDatasource(text: "Hello edited", images: original.images)
        let changedMediaURL = makeDatasource(
            text: "Hello",
            images: [
                ImageAttachment(
                    primary: "image-1",
                    url: try XCTUnwrap(URL(string: "https://files.example.com/new.jpg")),
                    size: CGSize(width: 100, height: 80)
                )
            ]
        )

        XCTAssertNotEqual(
            ChatMessageUpdatePolicy.contentSignature(for: original),
            ChatMessageUpdatePolicy.contentSignature(for: changedText)
        )
        XCTAssertNotEqual(
            ChatMessageUpdatePolicy.contentSignature(for: original),
            ChatMessageUpdatePolicy.contentSignature(for: changedMediaURL)
        )
    }

    func testSendingStateChangeStillInvalidatesContentUpdate() {
        let sending = makeDatasource(state: .sending, indicator: .sending)
        let read = makeDatasource(state: .read, indicator: .read)

        XCTAssertTrue(ChatMessageUpdatePolicy.shouldUpdateContent(old: sending, new: read))
    }

    func testSimpleStateReadAndDownloadChangesUseContentOnlyDiff() {
        let old = makeDatasource(
            state: .sending,
            indicator: .sending,
            isRead: false,
            isDownloaded: false
        )
        let new = makeDatasource(
            state: .read,
            indicator: .read,
            isRead: true,
            isDownloaded: true
        )
        let diff = ChatDatasourceCoordinator.diff(
            old: .init(items: [old]),
            new: .init(items: [new]),
            oldSizeProvider: { _ in CGSize(width: 220, height: 72) },
            newSizeProvider: { _ in CGSize(width: 220, height: 72) }
        )

        XCTAssertEqual(diff.contentOnlyUpdates, [
            ChatMessageContentUpdate(primary: "message-1", indexPath: IndexPath(row: 0, section: 0))
        ])
        XCTAssertTrue(diff.reloads.isEmpty)
        XCTAssertFalse(diff.hasCollectionUpdates)
    }

    func testLargeVoicePCMUsesStableHashWithoutFullArrayString() {
        let pcm = (0..<4_096).map { Float($0) / 1_000 }
        let original = makeDatasource(audios: [makeAudio(primary: "voice-1", pcm: pcm)])
        var changedPCM = pcm
        changedPCM[2_048] = 42
        let changed = makeDatasource(audios: [makeAudio(primary: "voice-1", pcm: changedPCM)])

        let signature = ChatMessageUpdatePolicy.contentSignature(for: original)

        XCTAssertNotEqual(signature, ChatMessageUpdatePolicy.contentSignature(for: changed))
        XCTAssertLessThan(String(describing: signature).count, 1_000)
        XCTAssertFalse(String(describing: signature).contains("0.000,0.001,0.002"))
    }

    func testNestedForwardDisplayFieldChangeInvalidatesSignature() {
        let original = makeDatasource(forwards: [
            makeForward(primary: "forward-1", subforwards: [
                makeForward(primary: "nested-1", text: "Nested body")
            ])
        ])
        let changed = makeDatasource(forwards: [
            makeForward(primary: "forward-1", subforwards: [
                makeForward(primary: "nested-1", text: "Nested body edited")
            ])
        ])

        XCTAssertNotEqual(
            ChatMessageUpdatePolicy.contentSignature(for: original),
            ChatMessageUpdatePolicy.contentSignature(for: changed)
        )
        XCTAssertTrue(ChatMessageUpdatePolicy.shouldUpdateContent(old: original, new: changed))
    }

    private func makeDatasource(
        primary: String = "message-1",
        text: String = "Hello",
        state: MessageStorageItem.MessageSendingState = .sending,
        indicator: IndicatorType = .sending,
        images: [ImageAttachment] = [],
        videos: [VideoAttachment] = [],
        locations: [LocationAttachment] = [],
        contacts: [ContactAttachment] = [],
        files: [FileAttachment] = [],
        audios: [AudioAttachment] = [],
        forwards: [MessageAttachment] = [],
        isRead: Bool = true,
        isDownloaded: Bool = true
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: "romeo@example.com",
            owner: "owner@example.com",
            outgoing: true,
            sender: Sender(id: "owner@example.com", displayName: "Owner"),
            messageId: "\(primary)-message-id",
            sentDate: Date(timeIntervalSince1970: 100),
            editDate: nil,
            kind: .attributedText(NSAttributedString(string: text)),
            withAuthor: false,
            withAvatar: false,
            error: state == .error,
            errorType: "",
            canPinMessage: false,
            canEditMessage: true,
            canDeleteMessage: true,
            forwards: forwards,
            isOutgoing: true,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: isDownloaded,
            state: state,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: "archived-1",
            queryIds: nil,
            isRead: isRead,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: images,
            videos: videos,
            locations: locations,
            contacts: contacts,
            files: files,
            audios: audios,
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: indicator,
            avatarUrl: nil,
            attributedAuthor: nil
        )
    }

    private func makeAudio(
        primary: String,
        url: URL? = URL(string: "file:///voice.ogg"),
        pcm: [Float] = [0.2, 0.5]
    ) -> AudioAttachment {
        AudioAttachment(
            primary: primary,
            url: url,
            size: 10,
            name: "voice",
            duration: 8,
            downloaded: true,
            pcm: pcm
        )
    }

    private func makeForward(
        primary: String,
        text: String = "Forward body",
        subforwards: [MessageAttachment] = []
    ) -> MessageAttachment {
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
            subforwards: subforwards
        )
    }
}
