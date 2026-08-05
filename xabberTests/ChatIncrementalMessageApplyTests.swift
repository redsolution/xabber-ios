import XCTest
@testable import xabber

final class ChatIncrementalMessageApplyTests: XCTestCase {
    func testHundredEventBurstCoalescesByStableIdentityAndNewestRevision() {
        var accumulator = ChatIncrementalMessageMutationAccumulator<String>()

        for revision in UInt64(1)...UInt64(100) {
            let primary = "message-\(revision % 10)"
            accumulator.enqueue(.upsert(
                identity: ChatIncrementalMessageIdentity(
                    primary: primary,
                    messageId: "origin-\(revision % 10)",
                    archivedId: nil
                ),
                revision: revision,
                payload: "revision-\(revision)"
            ))
        }

        let batch = accumulator.drain()

        XCTAssertEqual(batch.enqueuedMutationCount, 100)
        XCTAssertEqual(batch.mutations.count, 10)
        XCTAssertEqual(batch.applyCount, 1)
        XCTAssertEqual(Set(batch.mutations.map(\.identity.coalescingKey)).count, 10)
        XCTAssertEqual(batch.mutations.map(\.revision).max(), 100)
        XCTAssertTrue(accumulator.isEmpty)
    }

    func testStaleRevisionCannotOverwriteNewerMutation() throws {
        var accumulator = ChatIncrementalMessageMutationAccumulator<String>()
        let identity = ChatIncrementalMessageIdentity(
            primary: "optimistic",
            messageId: "origin-1",
            archivedId: nil
        )

        accumulator.enqueue(.upsert(identity: identity, revision: 9, payload: "new"))
        accumulator.enqueue(.upsert(identity: identity, revision: 8, payload: "stale"))

        let mutation = try XCTUnwrap(accumulator.drain().mutations.first)
        XCTAssertEqual(mutation.revision, 9)
        XCTAssertEqual(mutation.payload, "new")
    }

    func testStaleArchiveAliasMutationCannotDeleteReconciledServerItem() {
        var reducer = ChatIncrementalResidentReducer()
        let optimistic = message(primary: "optimistic-owner", messageId: "")
        let server = message(
            primary: "server-owner",
            messageId: "",
            archivedId: "archive-42",
            state: .deliver
        )
        let reconciled = reducer.apply(
            currentItems: [optimistic],
            mutations: [
                .upsert(
                    identity: ChatIncrementalMessageIdentity(primary: "optimistic-owner", messageId: nil, archivedId: "archive-42"),
                    revision: 9,
                    payload: server
                )
            ],
            isResidentAtLiveTail: true,
            hardLimit: 20
        )

        let stale = reducer.apply(
            currentItems: reconciled.items,
            mutations: [
                .delete(
                    identity: ChatIncrementalMessageIdentity(primary: "stale-owner", messageId: nil, archivedId: "archive-42"),
                    revision: 8
                )
            ],
            isResidentAtLiveTail: true,
            hardLimit: 20
        )

        XCTAssertEqual(stale.items.map(\.primary), ["server-owner"])
        XCTAssertEqual(stale.diagnostics.ignoredStaleMutationCount, 1)
    }

    func testLatestObservationSkipsIdenticalMessageUpsertButKeepsMetadataRefresh() {
        let optimistic = ChatIncrementalMessageIdentity(
            primary: "optimistic-owner",
            messageId: "origin-1",
            archivedId: nil
        )
        let server = ChatIncrementalMessageIdentity(
            primary: "server-owner",
            messageId: "origin-1",
            archivedId: "archive-42"
        )

        XCTAssertEqual(
            ChatIncrementalLatestObservationPolicy.action(previous: nil, current: optimistic),
            .upsert
        )
        XCTAssertEqual(
            ChatIncrementalLatestObservationPolicy.action(previous: optimistic, current: optimistic),
            .metadataOnly
        )
        XCTAssertEqual(
            ChatIncrementalLatestObservationPolicy.action(previous: optimistic, current: server),
            .upsert
        )
        XCTAssertEqual(
            ChatIncrementalLatestObservationPolicy.action(previous: server, current: nil),
            .delete
        )
    }

    func testOptimisticEchoReconcilesInPlaceWithoutDuplicateOrStructuralChange() {
        var reducer = ChatIncrementalResidentReducer()
        let optimistic = message(
            primary: "optimistic-owner",
            messageId: "origin-1",
            archivedId: ""
        )
        let echo = message(
            primary: "server-owner",
            messageId: "origin-1",
            archivedId: "archive-42",
            state: .deliver
        )

        let result = reducer.apply(
            currentItems: [optimistic],
            mutations: [
                .upsert(
                    identity: ChatIncrementalMessageIdentity(message: echo),
                    revision: 2,
                    payload: echo
                )
            ],
            isResidentAtLiveTail: true,
            hardLimit: 20
        )

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.primary, "server-owner")
        XCTAssertEqual(result.items.first?.archivedId, "archive-42")
        XCTAssertEqual(result.changeSet.updatedStablePrimaries, ["optimistic-owner"])
        XCTAssertTrue(result.changeSet.insertedPrimaries.isEmpty)
        XCTAssertTrue(result.changeSet.deletedPrimaries.isEmpty)
    }

    func testServerEchoUpsertWinsAliasDeletionInEitherRealmCallbackOrder() throws {
        let optimisticIdentity = ChatIncrementalMessageIdentity(
            primary: "optimistic-owner",
            messageId: "origin-1",
            archivedId: nil
        )
        let serverIdentity = ChatIncrementalMessageIdentity(
            primary: "server-owner",
            messageId: "origin-1",
            archivedId: "archive-42"
        )

        for upsertFirst in [true, false] {
            var accumulator = ChatIncrementalMessageMutationAccumulator<String>()
            let upsert = ChatIncrementalMessageMutation.upsert(
                identity: serverIdentity,
                revision: upsertFirst ? 1 : 2,
                payload: "server"
            )
            let delete = ChatIncrementalMessageMutation<String>.delete(
                identity: optimisticIdentity,
                revision: upsertFirst ? 2 : 1
            )
            if upsertFirst {
                accumulator.enqueue(upsert)
                accumulator.enqueue(delete)
            } else {
                accumulator.enqueue(delete)
                accumulator.enqueue(upsert)
            }

            let mutation = try XCTUnwrap(accumulator.drain().mutations.first)
            XCTAssertEqual(mutation.identity.primary, "server-owner")
            XCTAssertEqual(mutation.payload, "server")
        }
    }

    func testAppendAtLiveTailTrimsOppositeEdgeInSameApply() {
        var reducer = ChatIncrementalResidentReducer()
        let current = (0..<4).map {
            message(primary: "message-\($0)", messageId: "origin-\($0)", date: TimeInterval($0))
        }
        let newest = message(primary: "message-4", messageId: "origin-4", date: 4)

        let result = reducer.apply(
            currentItems: current,
            mutations: [
                .upsert(
                    identity: ChatIncrementalMessageIdentity(message: newest),
                    revision: 1,
                    payload: newest
                )
            ],
            isResidentAtLiveTail: true,
            hardLimit: 4
        )

        XCTAssertEqual(result.items.map(\.primary), ["message-1", "message-2", "message-3", "message-4"])
        XCTAssertEqual(result.changeSet.insertedPrimaries, ["message-4"])
        XCTAssertEqual(result.changeSet.trimmedPrimaries, ["message-0"])
        XCTAssertEqual(result.diagnostics.applyCount, 1)
    }

    func testHistoricalArchiveUpsertDoesNotMutateLiveTailResidentWindow() {
        var reducer = ChatIncrementalResidentReducer()
        let current = (240..<320).map {
            message(
                primary: "message-\($0)",
                messageId: "origin-\($0)",
                archivedId: "\($0)",
                date: TimeInterval($0),
                outgoing: false
            )
        }
        let historical = message(
            primary: "message-239",
            messageId: "origin-239",
            archivedId: "239",
            date: 239,
            outgoing: false
        )

        let result = reducer.apply(
            currentItems: current,
            mutations: [
                .upsert(
                    identity: ChatIncrementalMessageIdentity(message: historical),
                    revision: 1,
                    payload: historical
                )
            ],
            isResidentAtLiveTail: true,
            hardLimit: 480
        )

        XCTAssertEqual(result.items.map(\.primary), current.map(\.primary))
        XCTAssertTrue(result.changeSet.isEmpty)
        XCTAssertEqual(result.diagnostics.appliedMutationCount, 0)
    }

    func testGenuineNewerIncomingStillAppendsAtLiveTail() {
        var reducer = ChatIncrementalResidentReducer()
        let current = (240..<320).map {
            message(
                primary: "message-\($0)",
                messageId: "origin-\($0)",
                archivedId: "\($0)",
                date: TimeInterval($0),
                outgoing: false
            )
        }
        let incoming = message(
            primary: "message-320",
            messageId: "origin-320",
            archivedId: "320",
            date: 320,
            outgoing: false
        )

        let result = reducer.apply(
            currentItems: current,
            mutations: [
                .upsert(
                    identity: ChatIncrementalMessageIdentity(message: incoming),
                    revision: 1,
                    payload: incoming
                )
            ],
            isResidentAtLiveTail: true,
            hardLimit: 480
        )

        XCTAssertEqual(result.items.count, 81)
        XCTAssertEqual(result.items.last?.primary, "message-320")
        XCTAssertEqual(result.changeSet.insertedPrimaries, ["message-320"])
        XCTAssertEqual(result.diagnostics.appliedMutationCount, 1)
    }

    func testOutOfOrderNewerBatchUsesOriginalLiveTailBoundary() {
        var reducer = ChatIncrementalResidentReducer()
        let current = (240..<320).map {
            message(
                primary: "message-\($0)",
                messageId: "origin-\($0)",
                archivedId: "\($0)",
                date: TimeInterval($0),
                outgoing: false
            )
        }
        let newestFirst = message(
            primary: "message-321",
            messageId: "origin-321",
            archivedId: "321",
            date: 321,
            outgoing: false
        )
        let earlierSecond = message(
            primary: "message-320",
            messageId: "origin-320",
            archivedId: "320",
            date: 320,
            outgoing: false
        )

        let result = reducer.apply(
            currentItems: current,
            mutations: [
                .upsert(
                    identity: ChatIncrementalMessageIdentity(message: newestFirst),
                    revision: 1,
                    payload: newestFirst
                ),
                .upsert(
                    identity: ChatIncrementalMessageIdentity(message: earlierSecond),
                    revision: 2,
                    payload: earlierSecond
                )
            ],
            isResidentAtLiveTail: true,
            hardLimit: 480
        )

        XCTAssertEqual(result.items.suffix(2).map(\.primary), ["message-320", "message-321"])
        XCTAssertEqual(
            result.changeSet.insertedPrimaries,
            ["message-321", "message-320"]
        )
        XCTAssertEqual(result.diagnostics.appliedMutationCount, 2)
    }

    func testUnknownIncomingAwayFromLiveTailDoesNotReplaceResidentWindow() {
        var reducer = ChatIncrementalResidentReducer()
        let current = (0..<4).map {
            message(primary: "message-\($0)", messageId: "origin-\($0)", date: TimeInterval($0))
        }
        let incoming = message(primary: "message-10", messageId: "origin-10", date: 10, outgoing: false)

        let result = reducer.apply(
            currentItems: current,
            mutations: [
                .upsert(
                    identity: ChatIncrementalMessageIdentity(message: incoming),
                    revision: 1,
                    payload: incoming
                )
            ],
            isResidentAtLiveTail: false,
            hardLimit: 4
        )

        XCTAssertEqual(result.items.map(\.primary), current.map(\.primary))
        XCTAssertTrue(result.changeSet.insertedPrimaries.isEmpty)
        XCTAssertTrue(result.changeSet.updatedStablePrimaries.isEmpty)
        XCTAssertTrue(result.changeSet.deletedPrimaries.isEmpty)
        XCTAssertEqual(result.changeSet.nonResidentIncomingPrimaries, ["message-10"])
    }

    func testStableMessageIdentityTreatsServerPrimaryChangeAsContentUpdate() {
        let old = datasource(
            primary: "optimistic-owner",
            messageId: "origin-1",
            archivedId: nil,
            state: .sending,
            indicator: .sending
        )
        let new = datasource(
            primary: "server-owner",
            messageId: "origin-1",
            archivedId: "archive-42",
            state: .deliver,
            indicator: .received
        )

        let diff = ChatDatasourceCoordinator.diff(
            old: .init(items: [old]),
            new: .init(items: [new]),
            oldSizeProvider: { _ in CGSize(width: 280, height: 64) },
            newSizeProvider: { _ in CGSize(width: 280, height: 64) }
        )

        XCTAssertTrue(diff.inserts.isEmpty)
        XCTAssertTrue(diff.deletes.isEmpty)
        XCTAssertTrue(diff.moves.isEmpty)
        XCTAssertTrue(diff.reloads.isEmpty)
        XCTAssertEqual(diff.contentOnlyUpdates.count, 1)
        XCTAssertEqual(diff.changeMasksByPrimary["server-owner"], [.chrome])
    }

    func testDeliveryReadAndErrorTransitionsAreChromeOnly() {
        let sending = datasource(state: .sending, indicator: .sending, isRead: false)
        let delivered = datasource(state: .deliver, indicator: .received, isRead: false)
        let read = datasource(state: .read, indicator: .read, isRead: true)
        let failed = datasource(state: .error, indicator: .error, isRead: false)

        for candidate in [delivered, read, failed] {
            XCTAssertEqual(
                ChatMessageUpdatePolicy.changeMask(
                    old: sending,
                    new: candidate,
                    oldSize: CGSize(width: 280, height: 64),
                    newSize: CGSize(width: 280, height: 64)
                ),
                [.chrome]
            )
        }
    }

    func testTextAttachmentAndAvatarChangesProduceGranularMasks() {
        let base = datasource()
        let edited = datasource(text: "Edited")
        let media = datasource(images: [
            ImageAttachment(
                primary: "image-1",
                url: URL(string: "file:///tmp/image.jpg"),
                size: CGSize(width: 120, height: 80)
            )
        ])
        let avatarBase = datasource(withAvatar: true, avatarURL: "avatar-v1")
        let avatar = datasource(withAvatar: true, avatarURL: "avatar-v2")

        XCTAssertEqual(
            ChatMessageUpdatePolicy.changeMask(
                old: base,
                new: edited,
                oldSize: CGSize(width: 280, height: 64),
                newSize: CGSize(width: 280, height: 96)
            ),
            [.chrome, .text, .layout]
        )
        XCTAssertEqual(
            ChatMessageUpdatePolicy.changeMask(
                old: base,
                new: media,
                oldSize: CGSize(width: 280, height: 64),
                newSize: CGSize(width: 280, height: 160)
            ),
            [.layout, .attachments]
        )
        XCTAssertEqual(
            ChatMessageUpdatePolicy.changeMask(
                old: avatarBase,
                new: avatar,
                oldSize: CGSize(width: 280, height: 64),
                newSize: CGSize(width: 280, height: 64)
            ),
            [.avatar]
        )
    }

    func testOutgoingScrollNeverSelectsReloadDataFallback() {
        XCTAssertFalse(
            ChatOutgoingAutoScrollApplyPolicy.shouldUseImmediateReload(
                outgoingAutoScrollDecision: .scroll(IndexPath(item: 0, section: 3))
            )
        )
    }

    func testOutgoingTextMediaVoiceAndForwardUseOneTargetedInsertWithoutReload() {
        let media = ImageAttachment(
            primary: "image-1",
            url: URL(string: "file:///tmp/image.jpg"),
            size: CGSize(width: 120, height: 80)
        )
        let voice = AudioAttachment(
            primary: "voice-1",
            url: URL(string: "file:///tmp/voice.ogg"),
            size: 10,
            name: "voice",
            duration: 8,
            downloaded: true,
            pcm: [0.2, 0.5]
        )
        let forward = MessageAttachment(
            primary: "forward-1",
            author: "Sender",
            jid: "sender@example.com",
            outgoing: false,
            textMessage: NSAttributedString(string: "Forward body"),
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarker: NSAttributedString(string: "12:01"),
            subforwards: []
        )
        let candidates = [
            datasource(primary: "outgoing-text", messageId: "origin-text", text: "text"),
            datasource(primary: "outgoing-media", messageId: "origin-media", images: [media]),
            datasource(primary: "outgoing-voice", messageId: "origin-voice", audios: [voice]),
            datasource(primary: "outgoing-forward", messageId: "origin-forward", forwards: [forward])
        ]

        for candidate in candidates {
            let diff = ChatDatasourceCoordinator.diff(
                old: .init(items: []),
                new: .init(items: [candidate])
            )
            XCTAssertEqual(diff.inserts, IndexSet(integer: 0), candidate.primary)
            XCTAssertTrue(diff.deletes.isEmpty, candidate.primary)
            XCTAssertTrue(diff.reloads.isEmpty, candidate.primary)
            XCTAssertTrue(diff.contentOnlyUpdates.isEmpty, candidate.primary)
        }
    }

    func testIncomingViewportDecisionPinsNearTailAndPreservesAwayWithBadge() {
        let incoming = datasource(primary: "incoming", messageId: "incoming", outgoing: false)

        XCTAssertEqual(
            ChatIncrementalViewportPolicy.decision(
                insertedItems: [incoming],
                wasNearBottom: true,
                isResidentAtLiveTail: true
            ),
            .pinBottom
        )
        XCTAssertEqual(
            ChatIncrementalViewportPolicy.decision(
                insertedItems: [incoming],
                wasNearBottom: false,
                isResidentAtLiveTail: true
            ),
            .preserveViewport(showNewMessageBadge: true)
        )
        XCTAssertEqual(
            ChatIncrementalViewportPolicy.decision(
                insertedItems: [],
                wasNearBottom: false,
                isResidentAtLiveTail: false,
                nonResidentIncomingCount: 1
            ),
            .preserveViewport(showNewMessageBadge: true)
        )
    }

    private func message(
        primary: String,
        messageId: String,
        archivedId: String = "",
        date: TimeInterval = 1,
        outgoing: Bool = true,
        state: MessageStorageItem.MessageSendingState = .sending
    ) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = primary
        item.owner = "owner@example.com"
        item.opponent = "chat@example.com"
        item.messageId = messageId
        item.archivedId = archivedId
        item.date = Date(timeIntervalSince1970: date)
        item.sentDate = item.date
        item.outgoing = outgoing
        item.state = state
        item.conversationType = .regular
        return item
    }

    private func datasource(
        primary: String = "message-1",
        messageId: String = "origin-1",
        archivedId: String? = "archive-1",
        text: String = "Hello",
        outgoing: Bool = true,
        state: MessageStorageItem.MessageSendingState = .sending,
        indicator: IndicatorType = .sending,
        isRead: Bool = true,
        images: [ImageAttachment] = [],
        audios: [AudioAttachment] = [],
        forwards: [MessageAttachment] = [],
        withAvatar: Bool = false,
        avatarURL: String? = nil
    ) -> ChatViewController.Datasource {
        ChatViewController.Datasource(
            primary: primary,
            jid: "chat@example.com",
            owner: "owner@example.com",
            outgoing: outgoing,
            sender: Sender(id: outgoing ? "owner@example.com" : "chat@example.com", displayName: "Sender"),
            messageId: messageId,
            sentDate: Date(timeIntervalSince1970: 1),
            editDate: text == "Hello" ? nil : Date(timeIntervalSince1970: 2),
            kind: .attributedText(NSAttributedString(string: text)),
            withAuthor: false,
            withAvatar: withAvatar,
            error: state == .error,
            errorType: state == .error ? "failed" : "",
            canPinMessage: false,
            canEditMessage: outgoing,
            canDeleteMessage: true,
            forwards: forwards,
            isOutgoing: outgoing,
            isEdited: text != "Hello",
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: state,
            searchString: nil,
            errorMetadata: nil,
            messageWarningText: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: archivedId,
            queryIds: nil,
            isRead: isRead,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: false,
            images: images,
            videos: [],
            locations: [],
            contacts: [],
            files: [],
            audios: audios,
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: indicator,
            avatarUrl: avatarURL,
            attributedAuthor: nil
        )
    }
}
