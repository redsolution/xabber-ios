//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import XCTest
import RealmSwift
@testable import xabber

final class ChatSearchResultPresentationTests: XCTestCase {
    func testLegacyRawArchivedIdUsesPrimaryStableIdentity() throws {
        let item = makeMessage(primary: "local-1", archivedId: "archive-1")

        let result = try XCTUnwrap(ChatSearchResultMapper.map(item, context: regularContext))

        XCTAssertEqual(result.id, .primary("local-1"))
        XCTAssertEqual(result.anchor.primary, "local-1")
        XCTAssertEqual(result.anchor.archivedId, "archive-1")
    }

    func testMAMSearchAnchorKeepsRawStanzaIDSeparateFromTypedCursor() throws {
        let item = makeMessage(primary: "local-1", archivedId: "stanza-100")
        item.mamArchiveId = "mam-200"

        let result = try XCTUnwrap(ChatSearchResultMapper.map(item, context: regularContext))

        XCTAssertEqual(result.id, .archived("mam-200"))
        XCTAssertEqual(result.anchor.archivedId, "stanza-100")
        XCTAssertEqual(result.anchor.archiveCursorID, "mam-200")
    }

    func testEmptyArchivedIdFallsBackToPrimaryWithoutBodyOrDateIdentity() throws {
        let first = makeMessage(primary: "local-1", archivedId: "", body: "first", date: Date(timeIntervalSince1970: 10))
        let second = makeMessage(primary: "local-1", archivedId: "", body: "second", date: Date(timeIntervalSince1970: 20))

        let firstResult = try XCTUnwrap(ChatSearchResultMapper.map(first, context: regularContext))
        let secondResult = try XCTUnwrap(ChatSearchResultMapper.map(second, context: regularContext))

        XCTAssertEqual(firstResult.id, .primary("local-1"))
        XCTAssertEqual(firstResult.id, secondResult.id)
    }

    func testScopeIsCarriedAndMismatchedItemsAreRejected() throws {
        let matching = makeMessage(primary: "matching", archivedId: "1")
        let wrongOwner = makeMessage(primary: "wrong", archivedId: "2")
        wrongOwner.owner = "other@example.com"

        let result = try XCTUnwrap(ChatSearchResultMapper.map(matching, context: regularContext))

        XCTAssertEqual(result.scope, regularContext.scope)
        XCTAssertNil(ChatSearchResultMapper.map(wrongOwner, context: regularContext))
    }

    func testOrderingIsNewestFirstAndPreservesSuppliedOrderForTiedDates() throws {
        let older = makeMessage(primary: "older", archivedId: "9", date: Date(timeIntervalSince1970: 10))
        let tieArchiveLow = makeMessage(primary: "z-primary", archivedId: "10", date: Date(timeIntervalSince1970: 20))
        let tieArchiveHigh = makeMessage(primary: "a-primary", archivedId: "20", date: Date(timeIntervalSince1970: 20))
        let tiePrimaryHigh = makeMessage(primary: "primary-z", archivedId: "", date: Date(timeIntervalSince1970: 20))
        let tiePrimaryLow = makeMessage(primary: "primary-a", archivedId: "", date: Date(timeIntervalSince1970: 20))
        older.mamArchiveId = "9"
        tieArchiveLow.mamArchiveId = "10"
        tieArchiveHigh.mamArchiveId = "20"
        let mapped = try [older, tieArchiveLow, tieArchiveHigh, tiePrimaryLow, tiePrimaryHigh].map {
            try XCTUnwrap(ChatSearchResultMapper.map($0, context: regularContext))
        }

        let ordered = ChatSearchResultCollection.orderedAndDeduplicated(mapped)

        XCTAssertEqual(
            ordered.map(\.id),
            [.archived("10"), .archived("20"), .primary("primary-a"), .primary("primary-z"), .archived("9")]
        )
    }

    func testSearchIdentityKeepsWhitespaceAndLeadingZerosInMAMToken() throws {
        let item = makeMessage(primary: "local", archivedId: "raw")
        item.mamArchiveId = " 001 "
        let result = try XCTUnwrap(ChatSearchResultMapper.map(item, context: regularContext))
        XCTAssertEqual(result.id, .archived(" 001 "))
        XCTAssertEqual(result.anchor.archiveCursorID, " 001 ")
        XCTAssertEqual(ChatSearchSelectionIdentity.make(mamArchiveId: " 001 ", primary: "local", archivedId: "raw"), "mam: 001 ")
    }

    func testSearchDoesNotNormalizeDistinctUnicodeMAMIDsIntoOneResult() throws {
        let composed = "\u{e9}"
        let decomposed = "e\u{301}"
        let first = makeMessage(primary: "first", archivedId: "raw-first")
        first.mamArchiveId = composed
        let second = makeMessage(primary: "second", archivedId: "raw-second")
        second.mamArchiveId = decomposed
        let results = try [first, second].map {
            try XCTUnwrap(ChatSearchResultMapper.map($0, context: regularContext))
        }
        XCTAssertEqual(ChatSearchResultCollection.orderedAndDeduplicated(results).count, 2)
        XCTAssertFalse(ChatSearchSelectionIdentity.matches("mam:" + composed,
            mamArchiveId: decomposed, primary: "second", archivedId: "raw-second"))
        XCTAssertEqual(ChatTimelineOrdering.deduplicatedChronological([first, second]).count, 2)
    }

    func testOutgoingSenderTitleUsesLocalizedYou() throws {
        let item = makeMessage(primary: "outgoing", archivedId: "1")
        item.outgoing = true
        let context = ChatSearchResultMappingContext(
            scope: regularContext.scope,
            localizedYou: "Вы",
            contactDisplayName: "Andrew Nenakhov"
        )

        let result = try XCTUnwrap(ChatSearchResultMapper.map(item, context: context))

        XCTAssertEqual(result.senderTitle, "Вы")
    }

    func testIncomingRegularSenderUsesContactDisplayName() throws {
        let item = makeMessage(primary: "incoming", archivedId: "1")

        let result = try XCTUnwrap(ChatSearchResultMapper.map(item, context: regularContext))

        XCTAssertEqual(result.senderTitle, "Andrew Nenakhov")
    }

    func testIncomingGroupSenderUsesNicknameThenAuthorFallback() throws {
        let nicknameItem = makeMessage(
            primary: "nickname",
            archivedId: "1",
            conversationType: .group
        )
        appendGroupAuthor(
            to: nicknameItem,
            id: "nickname-author",
            nickname: "Group Nickname"
        )

        let authorItem = makeMessage(
            primary: "author",
            archivedId: "2",
            conversationType: .group
        )
        appendGroupAuthor(to: authorItem, id: "author-id")

        let context = mappingContext(conversationType: .group)
        let nicknameResult = try XCTUnwrap(ChatSearchResultMapper.map(nicknameItem, context: context))
        let authorResult = try XCTUnwrap(ChatSearchResultMapper.map(authorItem, context: context))

        XCTAssertEqual(nicknameResult.senderTitle, "Group Nickname")
        XCTAssertEqual(authorResult.senderTitle, "author-id")
    }

    private func appendGroupAuthor(
        to message: MessageStorageItem,
        id: String,
        nickname: String? = nil,
        avatarURL: String? = nil
    ) {
        let reference = MessageReferenceStorageItem()
        reference.primary = "\(message.primary)-group-author"
        reference.owner = message.owner
        reference.jid = message.opponent
        reference.messageId = message.primary
        reference.kind = .groupchat
        var metadata: [String: Any] = ["id": id]
        metadata["nickname"] = nickname ?? ""
        metadata["avatar_uri"] = avatarURL ?? ""
        reference.metadata = metadata
        message.references.append(reference)
    }

    func testSnippetIsDerivedWithoutMutatingOriginalBody() throws {
        let originalBody = "  first line\n second   line  "
        let item = makeMessage(primary: "snippet", archivedId: "1", body: originalBody)

        let result = try XCTUnwrap(ChatSearchResultMapper.map(item, context: regularContext))

        XCTAssertEqual(result.body, originalBody)
        XCTAssertEqual(result.snippet, "first line second line")
        XCTAssertEqual(item.body, originalBody)
    }

    func testDeliveryStateMappingCoversAllPresentationStates() throws {
        let cases: [(MessageStorageItem.MessageSendingState, ChatSearchResult.DeliveryState)] = [
            (.sended, .sent),
            (.deliver, .delivered),
            (.read, .read),
            (.error, .failed),
            (.notSended, .failed),
            (.none, .pending),
            (.sending, .pending),
            (.uploading, .pending)
        ]

        for (state, expected) in cases {
            let item = makeMessage(primary: "state-\(state.rawValue)", archivedId: "archive-\(state.rawValue)")
            item.state = state

            let result = try XCTUnwrap(ChatSearchResultMapper.map(item, context: regularContext))

            XCTAssertEqual(result.deliveryState, expected)
        }
    }

    func testMappedResultIsDetachedFromRealmRefresh() throws {
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "ChatSearchResultPresentationTests-\(name)"
        )
        let realm = try Realm(configuration: configuration)
        let item = makeMessage(primary: "detached", archivedId: "1", body: "before")
        try realm.write {
            realm.add(item)
        }
        let stored = try XCTUnwrap(realm.object(ofType: MessageStorageItem.self, forPrimaryKey: "detached"))

        let result = try XCTUnwrap(ChatSearchResultMapper.map(stored, context: regularContext))
        try realm.write {
            stored.body = "after"
            stored.archivedId = "changed"
        }

        XCTAssertEqual(result.body, "before")
        XCTAssertEqual(result.id, .primary("detached"))
        XCTAssertEqual(result.anchor.archivedId, "1")
    }

    func testDuplicateTypedMAMIdentityKeepsMoreCompleteResult() throws {
        let sparse = makeMessage(primary: "sparse", archivedId: "duplicate", body: "")
        let complete = makeMessage(primary: "complete", archivedId: "duplicate", body: "complete body")
        sparse.mamArchiveId = "200"
        complete.mamArchiveId = "200"
        complete.state = .read
        let mapped = try [sparse, complete].map {
            try XCTUnwrap(ChatSearchResultMapper.map($0, context: regularContext))
        }

        let results = ChatSearchResultCollection.orderedAndDeduplicated(mapped)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.anchor.primary, "complete")
        XCTAssertEqual(results.first?.body, "complete body")
        XCTAssertEqual(results.first?.deliveryState, .read)
    }

    func testLegacyRawAndTypedMAMIdentityCollisionKeepsBothResults() throws {
        let legacy = makeMessage(primary: "legacy", archivedId: "200")
        let typedMAM = makeMessage(primary: "typed-mam", archivedId: "100")
        typedMAM.mamArchiveId = "200"

        let results = ChatSearchResultCollection.orderedAndDeduplicated(
            try [legacy, typedMAM].map {
                try XCTUnwrap(ChatSearchResultMapper.map($0, context: regularContext))
            }
        )

        XCTAssertEqual(results.map(\.id).count, 2)
        XCTAssertTrue(results.contains { $0.id == .primary("legacy") })
        XCTAssertTrue(results.contains { $0.id == .archived("200") })
    }

    func testSearchSelectionNamespacesKeepMAMAndPrimaryCollisionsDistinct() {
        let typedMAM = ChatSearchSelectionIdentity.make(
            mamArchiveId: "200",
            primary: "typed-mam",
            archivedId: "100"
        )
        let legacyPrimary = ChatSearchSelectionIdentity.make(
            mamArchiveId: nil,
            primary: "200",
            archivedId: "200"
        )

        XCTAssertEqual(typedMAM, "mam:200")
        XCTAssertEqual(legacyPrimary, "primary:200")
        XCTAssertNotEqual(typedMAM, legacyPrimary)
        XCTAssertTrue(
            ChatSearchSelectionIdentity.matches(
                typedMAM,
                mamArchiveId: "200",
                primary: "typed-mam",
                archivedId: "100"
            )
        )
        XCTAssertFalse(
            ChatSearchSelectionIdentity.matches(
                typedMAM,
                mamArchiveId: nil,
                primary: "200",
                archivedId: "200"
            )
        )
    }

    func testPositionFormatterRejectsZeroAndOutOfBoundsPositions() {
        XCTAssertNil(ChatSearchResultPositionFormatter.text(currentIndex: nil, total: 3))
        XCTAssertNil(ChatSearchResultPositionFormatter.text(currentIndex: -1, total: 3))
        XCTAssertNil(ChatSearchResultPositionFormatter.text(currentIndex: 3, total: 3))
        XCTAssertNil(ChatSearchResultPositionFormatter.text(currentIndex: 0, total: 0))
        XCTAssertEqual(
            ChatSearchResultPositionFormatter.text(currentIndex: 0, total: 3),
            "1 of 3"
        )
        XCTAssertEqual(
            ChatSearchResultPositionFormatter.text(currentIndex: 2, total: 3),
            "3 of 3"
        )
    }

    private var regularContext: ChatSearchResultMappingContext {
        mappingContext(conversationType: .regular)
    }

    private func mappingContext(
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> ChatSearchResultMappingContext {
        ChatSearchResultMappingContext(
            scope: ChatSearchResult.Scope(
                owner: "owner@example.com",
                jid: "andrew@example.com",
                conversationTypeRawValue: conversationType.rawValue
            ),
            localizedYou: "You",
            contactDisplayName: "Andrew Nenakhov"
        )
    }

    private func makeMessage(
        primary: String,
        archivedId: String,
        body: String = "test body",
        date: Date = Date(timeIntervalSince1970: 100),
        conversationType: ClientSynchronizationManager.ConversationType = .regular
    ) -> MessageStorageItem {
        let item = MessageStorageItem()
        item.primary = primary
        item.archivedId = archivedId
        item.owner = "owner@example.com"
        item.opponent = "andrew@example.com"
        item.conversationType = conversationType
        item.body = body
        item.date = date
        item.outgoing = false
        item.state = .none
        return item
    }
}
