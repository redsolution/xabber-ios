import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

@MainActor
final class ChatSearchArchiveCursorIdentityTests: XCTestCase {
    private let owner = "owner@example.com"
    private let peer = "peer@example.com"
    private var previous: Realm.Configuration!
    private var realm: Realm!

    override func setUp() {
        super.setUp()
        previous = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = makeRealmMigrationConfiguration(
            scheme: XabberRealmSchema.current,
            inMemoryIdentifier: "SearchCursorIdentity-\(name)")
        realm = try! Realm()
    }

    override func tearDown() {
        realm = nil
        Realm.Configuration.defaultConfiguration = previous
        previous = nil
        super.tearDown()
    }

    func testActualDetachedSearchProducerOpensPersistedForkByExactCursorLoadedAndLocally() throws {
        let (base, fork) = try persistCollision()
        let detached = try actualSearchResult(uid: fork.mamArchiveId)
        XCTAssertEqual(detached.primary, base.primary,
            "The actual search producer synthesizes a logical primary without persisting the fork")
        XCTAssertNotEqual(detached.primary, fork.primary)
        let controller = controllerWithResult(detached)
        let request = try XCTUnwrap(controller.makeSearchResultOpenMessageRequest(at: 0))
        XCTAssertNil(request.anchor.messagePrimary,
            "An incoherent detached logical primary cannot constrain the verified MAM target")
        XCTAssertEqual(request.anchor.archiveCursor?.rawValue, fork.mamArchiveId)
        let loaded = [row(primary: base.primary, mamArchiveId: base.mamArchiveId),
                      row(primary: fork.primary, mamArchiveId: fork.mamArchiveId)]
        XCTAssertEqual(ChatLoadedMessageNavigationPolicy.index(in: loaded, for: request), 1)

        let token = ArchiveFreshnessToken.sessionMAM(connectionGeneration: 1, queryID: "search-proof")
        let segment = try XCTUnwrap(ArchiveCoverageSegment(
            orderedArchiveIDs: [base.mamArchiveId, fork.mamArchiveId].compactMap(ArchiveCursor.init(rawValue:)),
            reachesArchiveStart: true, reachesLiveEdge: true,
            fingerprint: token.fingerprint, isVerified: true))
        let key = ChatTimelineConversationKey(owner: owner, jid: peer, conversationType: .regular)
        let scope = try XCTUnwrap(ChatTimelineVerifiedScope(conversationKey: key,
            segment: segment, coverageGeneration: 1, freshnessToken: token))
        let provider = ChatLocalHistoryPageProvider(realm: realm, owner: owner, jid: peer, conversationType: .regular)
        var engine = ChatVirtualTimelineEngine(provider: provider, pageSize: 80,
            state: .empty, verifiedScope: scope)
        guard case .local(let snapshot) = engine.openAround(primary: request.anchor.messagePrimary,
            archiveCursor: try XCTUnwrap(request.anchor.archiveCursor), before: 1, after: 1) else {
            return XCTFail("Exact persisted fork must open through the unchanged verified provider proof")
        }
        XCTAssertTrue(snapshot.items.contains { $0.primary == fork.primary && $0.body == "fork body" })
    }

    func testExactSearchCursorWinsOverConflictingResidentPrimary() throws {
        let request = searchRequest(primary: "base", cursor: "mam-B")
        let rows = [row(primary: "base", mamArchiveId: "mam-A"), row(primary: "fork", mamArchiveId: "mam-B")]
        XCTAssertEqual(ChatLoadedMessageNavigationPolicy.index(in: rows, for: request), 1)
    }

    func testMissingExactSearchCursorDoesNotFallBackToPrimaryRawIDMessageIDOrDate() throws {
        let request = searchRequest(primary: "base", cursor: "mam-B")
        let rows = [row(primary: "base", archivedId: "shared-raw", mamArchiveId: "mam-A", messageId: "shared-origin")]
        XCTAssertNil(ChatLoadedMessageNavigationPolicy.index(in: rows, for: request))
    }

    func testDuplicateExactSearchCursorFailsClosed() {
        let request = searchRequest(primary: "base", cursor: "mam-B")
        let rows = [row(primary: "base", mamArchiveId: "mam-B"), row(primary: "other", mamArchiveId: "mam-B")]
        XCTAssertNil(ChatLoadedMessageNavigationPolicy.index(in: rows, for: request))
    }

    func testSearchWithoutVerifiedCursorKeepsPrimaryFirst() {
        let request = searchRequest(primary: "base", cursor: nil)
        let rows = [row(primary: "base", archivedId: "other", mamArchiveId: "mam-A"),
                    row(primary: "other", archivedId: "shared-raw", mamArchiveId: "mam-B")]
        XCTAssertEqual(ChatLoadedMessageNavigationPolicy.index(in: rows, for: request), 0)
    }

    func testRequestRetainsDurableCanonicalForkPrimaryWhenExactScopeAndCursorMatch() throws {
        let (_, fork) = try persistCollision()
        let request = try XCTUnwrap(controllerWithResult(fork).makeSearchResultOpenMessageRequest(at: 0))
        XCTAssertEqual(request.anchor.messagePrimary, fork.primary)
        XCTAssertEqual(request.anchor.archiveCursor?.rawValue, fork.mamArchiveId)
    }

    func testRequestDoesNotBorrowPrimaryFromForeignScopeOrMissingStorage() throws {
        for wrongScope in [false, true] {
            let item = MessageStorageItem()
            item.owner = owner; item.opponent = peer; item.conversationType = .regular
            item.messageId = "foreign-\(wrongScope)"; item.mamArchiveId = "mam-foreign"; item.updatePrimary()
            if wrongScope {
                let stored = MessageStorageItem(value: item)
                stored.opponent = "other@example.com"
                try realm.write { realm.add(stored) }
            }
            let request = try XCTUnwrap(controllerWithResult(item).makeSearchResultOpenMessageRequest(at: 0))
            XCTAssertNil(request.anchor.messagePrimary)
            XCTAssertEqual(request.anchor.archiveCursor?.rawValue, item.mamArchiveId)
        }
    }

    func testRawOnlySearchRetainsLegacyPrimaryWithoutGrantingMAMAuthority() throws {
        let item = MessageStorageItem()
        item.owner = owner; item.opponent = peer; item.conversationType = .regular
        item.messageId = "raw-only"; item.archivedId = "raw-id"; item.updatePrimary()
        let request = try XCTUnwrap(controllerWithResult(item).makeSearchResultOpenMessageRequest(at: 0))
        XCTAssertEqual(request.anchor.messagePrimary, item.primary)
        XCTAssertNil(request.anchor.archiveCursor)
    }

    func testUnknownStoredRawConversationTypeCannotLendARegularPrimaryConstraint() throws {
        let detached = MessageStorageItem()
        detached.owner = owner; detached.opponent = peer; detached.conversationType = .regular
        detached.messageId = "unknown-type"; detached.mamArchiveId = "mam-unknown-type"; detached.updatePrimary()
        let stored = MessageStorageItem(value: detached)
        stored.conversationType_ = "urn:xabber:test:unknown-conversation"
        try realm.write { realm.add(stored) }

        let request = try XCTUnwrap(controllerWithResult(detached).makeSearchResultOpenMessageRequest(at: 0))

        XCTAssertNil(request.anchor.messagePrimary, "Enum fallback must not establish exact stored scope")
        XCTAssertEqual(request.anchor.archiveCursor?.rawValue, detached.mamArchiveId)
    }

    private func controllerWithResult(_ item: MessageStorageItem) -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner; controller.jid = peer; controller.conversationType = .regular
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: peer, displayName: "Peer")
        let mapped = ChatSearchResultMapper.map(item, context: controller.inChatSearchResultMappingContext)!
        controller.searchMessagesQueue = [item]
        controller.searchResultPresentations = [mapped]
        return controller
    }

    private func persistCollision() throws -> (MessageStorageItem, MessageStorageItem) {
        let base = MessageStorageItem()
        base.owner = owner; base.opponent = peer; base.conversationType = .regular
        base.messageId = "shared-origin"; base.body = "base body"; base.mamArchiveId = "mam-A"
        base.archivedId = "shared-raw"; base.updatePrimary()
        let fork = MessageStorageItem()
        fork.owner = owner; fork.opponent = peer; fork.conversationType = .regular
        fork.messageId = base.messageId; fork.body = "fork body"; fork.mamArchiveId = "mam-B"
        fork.archivedId = "shared-raw"
        fork.primary = MessageStorageItem.disambiguatedArchivePrimary(messageId: fork.messageId,
            owner: owner, opponent: peer, conversationType: .regular, mamArchiveId: fork.mamArchiveId)
        XCTAssertTrue(fork.usesDisambiguatedArchiveIdentity)
        try realm.write { realm.add([base, fork]) }
        return (base, fork)
    }

    private func actualSearchResult(uid: String) throws -> MessageStorageItem {
        let manager = MessageArchiveManager(withOwner: owner)
        let stream = SearchCursorAuthenticatedStream()
        stream.myJID = XMPPJID(string: owner, resource: "test")
        manager.isExtendedArchiveAvailable = true
        defer {
            _ = manager.cancelPendingArchiveRequest(queryId: "synthetic-search")
            manager.finishEngineSearchPage(queryId: "synthetic-search")
            manager.abortDeferredCommit(queryId: "synthetic-search")
        }
        let callback = expectation(description: "actual detached search result")
        var received: MessageStorageItem?
        manager.requestArchive(stream, jid: peer, isContinues: false, conversationType: .regular,
            purpose: .engineSearchPage, queryId: "synthetic-search", searchText: "fork",
            requestCallbacks: .init(onMessage: { item, _ in received = item; callback.fulfill() }))
        let wire = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='\(owner)/test'>
          <result xmlns='urn:xmpp:mam:2' queryid='synthetic-search' id='\(uid)'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' from='\(peer)' to='\(owner)' type='chat' id='shared-origin'>
                <origin-id xmlns='urn:xmpp:sid:0' id='shared-origin'/><body>fork body</body>
              </message><delay xmlns='urn:xmpp:delay' stamp='2026-01-01T00:00:00Z'/>
            </forwarded>
          </result>
        </message>
        """)
        XCTAssertTrue(manager.readMessage(wire))
        wait(for: [callback], timeout: 2)
        return try XCTUnwrap(received)
    }

    private func searchRequest(primary: String?, cursor: String?) -> ChatOpenMessageRequest {
        ChatOpenMessageRequest(chatJid: peer, owner: owner, conversationType: .regular,
            anchor: .init(messagePrimary: primary, archivedId: "shared-raw",
                archiveCursor: cursor.flatMap(ArchiveCursor.init(rawValue:)), messageId: "shared-origin",
                authorId: nil, bodyFingerprint: nil, sourceDate: Date(timeIntervalSince1970: 1_700_000_000)),
            highlight: true, markReadOnVisible: false, source: .search)
    }
    private func row(
        primary: String = "message-1",
        archivedId: String? = "archived-1",
        mamArchiveId: String? = nil,
        messageId: String = "message-id-1",
        kind: MessageKind = .attributedText(NSAttributedString(string: "Hello")),
        isFakeMessage: Bool = false
    ) -> ChatViewController.Datasource {
        var datasource = ChatViewController.Datasource(
            primary: primary,
            jid: peer,
            owner: owner,
            outgoing: false,
            sender: Sender(id: "sender@example.com", displayName: "Sender"),
            messageId: messageId,
            sentDate: Date(timeIntervalSince1970: 1_700_000_000),
            editDate: nil,
            kind: kind,
            withAuthor: false,
            withAvatar: false,
            error: false,
            errorType: "",
            canPinMessage: true,
            canEditMessage: false,
            canDeleteMessage: true,
            forwards: [],
            isOutgoing: false,
            isEdited: false,
            groupchatAuthorRole: "",
            groupchatAuthorId: "",
            groupchatAuthorNickname: "",
            groupchatAuthorBadge: "",
            isHasAttachedMessages: false,
            isDownloaded: true,
            state: .read,
            searchString: nil,
            errorMetadata: nil,
            burnDate: -1,
            afterburnInterval: -1,
            archivedId: archivedId,
            queryIds: nil,
            isRead: true,
            selectedSearchResultId: nil,
            isHadHistoryGap: false,
            tailed: false,
            isFakeMessage: isFakeMessage,
            images: [],
            videos: [],
            files: [],
            audios: [],
            timeMarkerText: NSAttributedString(string: "12:00"),
            indicator: .read,
            avatarUrl: nil,
            attributedAuthor: nil
        )
        datasource.mamArchiveId = mamArchiveId
        return datasource
    }

}

private final class SearchCursorAuthenticatedStream: XMPPStream {
    override var isAuthenticated: Bool { true }
    override func send(_ element: DDXMLElement) {}
}
