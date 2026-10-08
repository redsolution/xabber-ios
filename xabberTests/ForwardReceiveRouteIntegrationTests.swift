import XCTest
import RealmSwift
import XMPPFramework
@testable import xabber

/// Exercises the receive entry points with an independently authored rich
/// carrier. These fixtures do not prove live server or deployed web behavior.
@MainActor
final class ForwardReceiveRouteIntegrationTests: XCTestCase {
    private let owner = "forward-route-owner@example.test"
    private let peer = "forward-route-peer@example.test"
    private let author = "alice@example.test"
    private let group = "team@example.test"
    private let saved = "favorites.example.test"
    private let comment = "comment 😀 & own"
    private let queryID = "forward-route-query"
    private let delivery = Date(timeIntervalSince1970: 1_791_374_400)
    private var previousConfiguration: Realm.Configuration!
    private var realm: Realm!
    private var receivers: [MessageManager] = []

    override func setUp() {
        super.setUp()
        previousConfiguration = Realm.Configuration.defaultConfiguration
        Realm.Configuration.defaultConfiguration = .init(inMemoryIdentifier: name)
        realm = try! WRealm.safe()
    }

    override func tearDown() {
        receivers.forEach { $0.unsubscribeReceiver() }
        receivers.removeAll()
        realm = nil
        Realm.Configuration.defaultConfiguration = previousConfiguration
        super.tearDown()
    }

    func testRuntimePersistsRichGraphAndCanForwardOriginalPayloadAgain() throws {
        let manager = receiver()
        manager.receiveRuntime(try carrier())

        let row = try materialized(queued(manager), manager: manager)

        try assertRichProjection(row, outgoing: false)
        try assertPersistedCarrierCanBeForwarded(row)
    }

    func testMAMWrapperKeepsArchiveCursorSeparateFromRichCarrierIdentity() throws {
        let manager = receiver()
        manager.receiveArchived(try archive(carrier()))

        let item = try queued(manager)
        let row = try materialized(item, manager: manager)

        XCTAssertEqual(item.queryId, queryID)
        XCTAssertEqual(row.mamArchiveId, "mam-route-result")
        XCTAssertEqual(row.archivedId, "carrier-archive")
        XCTAssertEqual(row.messageId, "rich-carrier")
        try assertRichProjection(row, outgoing: false)
        try assertPersistedCarrierCanBeForwarded(row)
    }

    func testForeignResultBeforeOwnedMAMCannotReplaceArchiveDeliveryDate() throws {
        let manager = receiver()
        let original = try carrierWithoutDeliveryTime()
        let ownedResult = try XCTUnwrap(getMAMResultElement(try archive(original)))
        let message = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='\(owner)/ios'>
          <result xmlns='urn:example:foreign-mam' queryid='foreign-query' id='foreign-result'>
            <forwarded><delay stamp='1999-01-01T10:00:00Z'/></forwarded>
          </result>
          \(ownedResult.xmlString)
        </message>
        """)

        manager.receiveArchived(message)
        let row = try materialized(queued(manager), manager: manager)

        XCTAssertEqual(row.date, try XCTUnwrap("2026-10-08T10:00:00Z".xmppDate))
        XCTAssertEqual(row.mamArchiveId, "mam-route-result")
        try assertRichProjection(row, outgoing: false)
    }

    func testForeignDelayBeforeOwnedMAMDelayCannotReplaceArchiveDeliveryDate() throws {
        let manager = receiver()
        let message = try archive(carrierWithoutDeliveryTime(), leadingForwardedXML:
            "<delay xmlns='urn:example:foreign-delay' stamp='1999-01-01T10:00:00Z'/>")

        manager.receiveArchived(message)
        let row = try materialized(queued(manager), manager: manager)

        XCTAssertEqual(row.date, try XCTUnwrap("2026-10-08T10:00:00Z".xmppDate))
        XCTAssertEqual(row.mamArchiveId, "mam-route-result")
        try assertRichProjection(row, outgoing: false)
    }

    func testForeignOnlyDelayCannotManufactureAcceptedArchivedForward() throws {
        let manager = receiver()
        let message = try archive(carrierWithoutDeliveryTime(), delayXML:
            "<delay xmlns='urn:example:foreign-delay' stamp='2026-10-08T10:00:00Z'/>")

        manager.receiveArchived(message)

        XCTAssertTrue(manager.performMessageQueueSync { manager.queuedMessages.isEmpty })
        XCTAssertNil(manager.receiveTemporary(message))
    }

    func testDuplicateQualifiedMAMDelaysCannotChooseAnAmbiguousArchiveDate() throws {
        let manager = receiver()
        let message = try archive(carrierWithoutDeliveryTime(), leadingForwardedXML:
            "<delay xmlns='urn:xmpp:delay' stamp='1999-01-01T10:00:00Z'/>")

        manager.receiveArchived(message)

        XCTAssertTrue(manager.performMessageQueueSync { manager.queuedMessages.isEmpty })
        XCTAssertNil(manager.receiveTemporary(message))
    }

    func testForeignOuterTimeOrDelayCannotRescueMAMWithoutAnOwnedTimestamp() throws {
        for tag in ["time", "delay"] {
            let manager = receiver()
            let withoutDate = try archive(carrierWithoutDeliveryTime(), delayXML: "")
            let result = try XCTUnwrap(getMAMResultElement(withoutDate))
            let message = try XMPPMessage(xmlString: """
            <message xmlns='jabber:client' from='\(owner)' to='\(owner)/ios'>
              <\(tag) xmlns='urn:example:foreign-date' stamp='2026-10-08T10:00:00Z'/>
              \(result.xmlString)
            </message>
            """)

            manager.receiveArchived(message)

            XCTAssertTrue(manager.performMessageQueueSync { manager.queuedMessages.isEmpty }, tag)
            XCTAssertNil(manager.receiveTemporary(message), tag)
        }
    }

    func testQualifiedForwardedDeliveryTimePreservesLegacyMAMCompatibility() throws {
        let manager = receiver()
        let message = try archive(carrierWithoutDeliveryTime(), delayXML:
            "<time xmlns='https://xabber.com/protocol/delivery' stamp='2026-10-08T10:00:00Z'/>")

        manager.receiveArchived(message)
        let row = try materialized(queued(manager), manager: manager)

        XCTAssertEqual(row.date, try XCTUnwrap("2026-10-08T10:00:00Z".xmppDate))
        try assertRichProjection(row, outgoing: false)
    }

    func testQualifiedMAMDelayKeepsPriorityOverDifferentForwardedDeliveryTime() throws {
        let manager = receiver()
        let message = try archive(carrierWithoutDeliveryTime(), leadingForwardedXML:
            "<time xmlns='https://xabber.com/protocol/delivery' stamp='1999-01-01T10:00:00Z'/>")

        manager.receiveArchived(message)
        let row = try materialized(queued(manager), manager: manager)

        XCTAssertEqual(row.date, try XCTUnwrap("2026-10-08T10:00:00Z".xmppDate))
        try assertRichProjection(row, outgoing: false)
    }

    func testQualifiedOuterDeliveryTimePreservesLegacyMAMFallback() throws {
        let manager = receiver()
        let withoutDate = try archive(carrierWithoutDeliveryTime(), delayXML: "")
        let result = try XCTUnwrap(getMAMResultElement(withoutDate))
        let message = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='\(owner)/ios'>
          <time xmlns='https://xabber.com/protocol/delivery' stamp='2026-10-08T10:00:00Z'/>
          \(result.xmlString)
        </message>
        """)

        manager.receiveArchived(message)
        let row = try materialized(queued(manager), manager: manager)

        XCTAssertEqual(row.date, try XCTUnwrap("2026-10-08T10:00:00Z".xmppDate))
        try assertRichProjection(row, outgoing: false)
    }

    func testSentCarbonUsesDestinationConversationAndKeepsBothForwardAuthors() throws {
        let manager = receiver()
        manager.receiveCarbon(try carbon(carrier(outgoing: true), sent: true))

        let row = try materialized(queued(manager), manager: manager)

        try assertRichProjection(row, outgoing: true)
        try assertPersistedCarrierCanBeForwarded(row)
    }

    func testReceivedCarbonUsesSenderConversationAndKeepsRichForwardPayload() throws {
        let manager = receiver()
        manager.receiveCarbonForwarded(try carbon(carrier(), sent: false))

        let row = try materialized(queued(manager), manager: manager)

        try assertRichProjection(row, outgoing: false)
        try assertPersistedCarrierCanBeForwarded(row)
    }

    func testClientSyncQueueBoundaryRetainsGraphWithoutRuntimeUnreadAdmission() throws {
        let manager = receiver()
        let item = try XCTUnwrap(manager.receiveClientSyncRaw(try carrier(),
            groupchatUserCard: nil, isRead: true, state: .deliver, date: delivery))

        let row = try materialized(item, manager: manager)

        XCTAssertTrue(row.isRead)
        XCTAssertFalse(row.countsAsRuntimeUnread)
        try assertRichProjection(row, outgoing: false)
        try assertPersistedCarrierCanBeForwarded(row)
    }

    func testTemporaryMAMBoundaryRetainsRichGraphAndOuterResultCursor() throws {
        let manager = receiver()
        let item = try XCTUnwrap(manager.receiveTemporary(try archive(carrier())))

        let row = try materialized(item, manager: manager)

        XCTAssertEqual(row.mamArchiveId, "mam-route-result")
        XCTAssertFalse(row.countsAsRuntimeUnread)
        try assertRichProjection(row, outgoing: false)
        try assertPersistedCarrierCanBeForwarded(row)
    }

    func testSearchCallbackMaterializesSameRichGraphAsOrdinaryMAM() async throws {
        let manager = MessageArchiveManager(withOwner: owner)
        let delivered = expectation(description: "rich forwarded search result")
        var result: MessageStorageItem?
        installSearchCallback(manager) { row in
            result = row
            delivered.fulfill()
        }

        XCTAssertTrue(manager.readMessage(try archive(carrier())))
        await fulfillment(of: [delivered], timeout: 2)
        let row = try XCTUnwrap(result)

        XCTAssertEqual(row.mamArchiveId, "mam-route-result")
        try assertRichProjection(row, outgoing: false)
        try assertPersistedCarrierCanBeForwarded(row)
    }

    func testSyncSnapshotPreviewUsesOwnCommentAfterForwardFallbackElision() throws {
        let query = try DDXMLElement(xmlString: """
        <query xmlns='https://xabber.com/protocol/synchronization'>
          <conversation jid='\(peer)' type='urn:xabber:chat'>
            <metadata node='https://xabber.com/protocol/synchronization'>
              <last-message>\(try carrier().xmlString)</last-message>
            </metadata>
          </conversation>
        </query>
        """)
        let sync = ClientSynchronizationManager(withOwner: owner)

        let value = try XCTUnwrap(sync.prepareSyncConversations(query).first)
        let message = try XCTUnwrap(value.materializedElement()?.element(forName: "metadata")?
            .element(forName: "last-message")?.element(forName: "message", xmlns: "jabber:client"))
        let preview = try XCTUnwrap(LastChatListSyncPreviewParser.projection(owner: owner,
            conversationPrimary: "sync-route", lastMessageID: "rich-carrier", messageElement: message,
            encryption: value.lastMessageEncryption))

        XCTAssertEqual(preview.text, comment)
        XCTAssertFalse(preview.isAttachment)
        XCTAssertNil(preview.groupchatNickname)
        XCTAssertFalse(value.lastMessageWasConsumed)
    }

    func testSavedMAMKeepsMultiRootCarrierAndServiceConversation() throws {
        let message = try carrier(outgoing: true, destination: saved)

        let row = try XCTUnwrap(XMPPFavoritesManager(withOwner: owner).receiveSaved(
            message: archive(message), realm: realm, commitTransaction: true,
            favoritesNodeOverride: saved))

        try assertRichProjection(row, outgoing: true, opponent: saved)
        XCTAssertEqual(row.conversationType, .saved)
        XCTAssertFalse(row.isSavedForward)
        XCTAssertEqual(row.mamArchiveId, "mam-route-result")
        try assertPersistedCarrierCanBeForwarded(row, alreadySaved: true)
    }

    func testSavedCarbonStripsOnlyPureServiceWrapperAndRetainsCardAndOriginalFile() throws {
        let message = try pureSaveCarrier()

        let row = try XCTUnwrap(XMPPFavoritesManager(withOwner: owner).receiveSaved(
            message: carbon(message, sent: true), realm: realm, commitTransaction: true,
            favoritesNodeOverride: saved))

        XCTAssertEqual(row.opponent, saved)
        XCTAssertEqual(row.conversationType, .saved)
        XCTAssertTrue(row.isSavedForward)
        XCTAssertEqual(row.savedForwardAuthorJid, author)
        XCTAssertTrue(row.inlineForwards.isEmpty)
        XCTAssertEqual(row.body, "Original 😀 & text")
        XCTAssertEqual(row.references.filter { $0.kind == .media }.count, 1)
        let card = try XCTUnwrap(ForwardContactDataCodec.matchingCard(for: author,
            references: row.references.toArray()))
        XCTAssertEqual(card.nickname, "Ally")
        let snapshot = try XCTUnwrap(ForwardSourceLoader.load(ids: [row.primary], owner: owner, realm: realm).first)
        XCTAssertEqual(snapshot.message.from?.full, "\(author)/phone")
        XCTAssertEqual(snapshot.message.to?.full, "\(peer)/web")
        XCTAssertEqual(snapshot.message.elementID, "personal-original")
        XCTAssertEqual(snapshot.attributionCard, card)
        XCTAssertEqual(snapshot.message.element(forName: "opaque", xmlns: "urn:example:forward-payload")?
            .element(forName: "token")?.stringValue, "keep <value> & bytes")
    }

    func testMissingIMPPCardDoesNotDiscardReadableForwardOrOtherAuthorsCard() throws {
        let manager = receiver()
        let message = try carrier()
        let card = try XCTUnwrap(message.elements(forName: "reference").first {
            ForwardContactDataCodec.decode($0)?.jid == author
        })
        card.element(forName: "vcard", xmlns: ForwardContactDataCodec.vcardXMLNS)?
            .element(forName: "impp")?.detach()
        manager.receiveRuntime(message)

        let row = try materialized(queued(manager), manager: manager)
        let personal = try XCTUnwrap(row.inlineForwards.first { $0.messageId == "personal-original" })
        let groupForward = try XCTUnwrap(row.inlineForwards.first { $0.messageId == "group-original" })

        XCTAssertEqual(row.body, comment)
        XCTAssertEqual(row.inlineForwards.count, 2)
        XCTAssertEqual(personal.body.trimmingCharacters(in: .whitespacesAndNewlines), "Original 😀 & text")
        XCTAssertEqual(personal.attribution.routingJID, author)
        XCTAssertFalse(personal.references.contains { $0.kind == .forwardContactData })
        XCTAssertEqual(groupForward.attribution.groupName, "Team Snapshot")
        XCTAssertTrue(row.save(commitTransaction: true, silentNotifications: true))
        XCTAssertEqual(try ForwardSourceLoader.load(ids: [row.primary], owner: owner, realm: realm).count, 1)
    }

    func testOverlappingForwardRemainsReadableFallbackThroughReceiveAndStorage() throws {
        let manager = receiver()
        let message = try carrier()
        let second = try XCTUnwrap(message.elements(forName: "reference").first {
            $0.attributeStringValue(forName: "begin") == "72"
        })
        second.removeAttribute(forName: "begin")
        second.addAttribute(withName: "begin", stringValue: "0")
        manager.receiveRuntime(message)

        let row = try materialized(queued(manager), manager: manager)

        XCTAssertEqual(row.inlineForwards.map(\.messageId), ["personal-original"])
        XCTAssertEqual(row.body, "Team:\n> Group text\n\(comment)")
        XCTAssertTrue(row.save(commitTransaction: true, silentNotifications: true))
        let stored = try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self,
            forPrimaryKey: row.primary + "_stanza"))
        XCTAssertTrue(stored.stanza.contains("group-original"))
        XCTAssertTrue(stored.stanza.contains("Team:"))
    }

    func testIncomingRewriteReplacesCommentAndKeepsReForwardableOriginalGraph() throws {
        let manager = receiver()
        manager.receiveRuntime(try carrier())
        let row = try materialized(queued(manager), manager: manager)
        XCTAssertTrue(row.save(commitTransaction: true, silentNotifications: true))
        let replacement = try carrier()
        let body = try XCTUnwrap(replacement.element(forName: "body", xmlns: "jabber:client"))
        body.stringValue = body.stringValue?.replacingOccurrences(of: comment, with: "updated 😀 & own")
        let decoration = try XCTUnwrap(replacement.elements(forName: "reference").first {
            $0.attributeStringValue(forName: "type") == "decoration"
        })
        // Both comments contain the same escaped scalar and display lengths.
        decoration.removeAttribute(forName: "end")
        decoration.addAttribute(withName: "end", integerValue: 113)
        replacement.addChild(try DDXMLElement(xmlString:
            "<replaced xmlns='https://xabber.com/protocol/rewrite' stamp='2026-10-08T11:00:00Z'/>"))
        let notification = try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='\(owner)' type='headline'>
          <replace xmlns='https://xabber.com/protocol/rewrite#notify' conversation='\(peer)'
                   type='urn:xabber:chat' id='carrier-archive' version='2'>
            \(replacement.xmlString)
          </replace>
        </message>
        """)

        XCTAssertTrue(MessageDeleteManager(withOwner: owner).readRewriteNotify(notification))

        try assertRichProjection(row, outgoing: false, expectedComment: "updated 😀 & own")
        XCTAssertNotNil(row.editDate)
        try assertPersistedCarrierCanBeForwarded(row, alreadySaved: true)
    }

    private func receiver() -> MessageManager {
        let manager = MessageManager(withOwner: owner, activeStream: false)
        manager.unsubscribeReceiver()
        receivers.append(manager)
        return manager
    }

    private func queued(_ manager: MessageManager) throws -> MessageManager.MessageQueueItem {
        try XCTUnwrap(manager.performMessageQueueSync { manager.queuedMessages.first })
    }

    private func materialized(_ item: MessageManager.MessageQueueItem,
                              manager: MessageManager) throws -> MessageStorageItem {
        var batch: MessageManager.ProcessedQueueBatch?
        manager.processQueue([item]) { batch = $0 }
        return try XCTUnwrap(batch?.messages.first)
    }

    private func assertRichProjection(_ row: MessageStorageItem, outgoing: Bool,
                                      opponent: String? = nil, expectedComment: String? = nil,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let ownComment = expectedComment ?? comment
        XCTAssertEqual(row.owner, owner, file: file, line: line)
        XCTAssertEqual(row.opponent, opponent ?? peer, file: file, line: line)
        XCTAssertEqual(row.outgoing, outgoing, file: file, line: line)
        XCTAssertEqual(row.body, ownComment, file: file, line: line)
        XCTAssertEqual(row.inlineForwards.map(\.messageId), ["personal-original", "group-original"], file: file, line: line)
        let personal = try XCTUnwrap(row.inlineForwards.first { $0.messageId == "personal-original" }, file: file, line: line)
        XCTAssertEqual(personal.parentId, row.primary, file: file, line: line)
        XCTAssertEqual(personal.body.trimmingCharacters(in: .whitespacesAndNewlines), "Original 😀 & text", file: file, line: line)
        XCTAssertEqual(personal.attribution.routingJID, author, file: file, line: line)
        XCTAssertEqual(personal.attribution.senderName, "Ally", file: file, line: line)
        XCTAssertNotNil(personal.originalDate, file: file, line: line)
        let media = try XCTUnwrap(personal.references.first { $0.kind == .media }, file: file, line: line)
        XCTAssertEqual(media.url, "https://files.example.test/a.pdf", file: file, line: line)
        let team = try XCTUnwrap(row.inlineForwards.first { $0.messageId == "group-original" }, file: file, line: line)
        XCTAssertEqual(team.attribution.routingJID, group, file: file, line: line)
        XCTAssertEqual(team.attribution.sourceGroupJID, group, file: file, line: line)
        XCTAssertEqual(team.attribution.memberID, "member-1", file: file, line: line)
        XCTAssertEqual(team.attribution.displayableAuthorJID, "bob@example.test", file: file, line: line)
        XCTAssertEqual(team.attribution.groupName, "Team Snapshot", file: file, line: line)
        XCTAssertEqual(team.attribution.groupPrivacy, .incognito, file: file, line: line)
        XCTAssertEqual(team.attribution.senderName, "Group Member", file: file, line: line)
        XCTAssertNil(team.originalDate, file: file, line: line)
        let markup = try XCTUnwrap(row.references.first { $0.kind == .markup }, file: file, line: line)
        XCTAssertEqual(markup.begin, 0, file: file, line: line)
        XCTAssertEqual(markup.end, ownComment.utf16.count, file: file, line: line)
        XCTAssertEqual(row.references.filter { $0.kind == .forwardContactData }.count, 2, file: file, line: line)
    }

    private func assertPersistedCarrierCanBeForwarded(_ row: MessageStorageItem, alreadySaved: Bool = false,
                                                     file: StaticString = #filePath, line: UInt = #line) throws {
        if !alreadySaved {
            XCTAssertTrue(row.save(commitTransaction: true, silentNotifications: true), file: file, line: line)
        }
        let raw = try XCTUnwrap(realm.object(ofType: MessageStanzaStorageItem.self,
            forPrimaryKey: row.primary + "_stanza"), file: file, line: line)
        XCTAssertEqual(raw.owner, owner, file: file, line: line)
        let sources = try ForwardSourceLoader.load(ids: [row.primary], owner: owner, realm: realm)
        let units = try ForwardSendPlanner.plan(sources: sources, comment: "")
        let originals = units.flatMap(\.refs).compactMap { inlineForwardPayloadMessage(from: $0)?.message }
        let personal = try XCTUnwrap(originals.first { $0.attributeStringValue(forName: "id") == "personal-original" }, file: file, line: line)
        XCTAssertEqual(personal.attributeStringValue(forName: "from"), "\(author)/phone", file: file, line: line)
        XCTAssertEqual(personal.attributeStringValue(forName: "to"), "\(peer)/web", file: file, line: line)
        XCTAssertEqual(personal.element(forName: "opaque", xmlns: "urn:example:forward-payload")?
            .element(forName: "token")?.stringValue, "keep <value> & bytes", file: file, line: line)
        XCTAssertTrue(personal.xmlString.contains("<![CDATA[keep <value> & bytes]]>"), file: file, line: line)
        let team = try XCTUnwrap(originals.first { $0.attributeStringValue(forName: "id") == "group-original" }, file: file, line: line)
        XCTAssertEqual(team.attributeStringValue(forName: "from"), "\(group)/server", file: file, line: line)
        XCTAssertEqual(team.element(forName: "x", xmlns: "https://xabber.com/protocol/groups")?
            .element(forName: "user")?.element(forName: "jid")?.stringValue, "bob@example.test", file: file, line: line)
        let cards = units.flatMap(\.refs).compactMap(ForwardContactDataCodec.decode)
        XCTAssertTrue(cards.contains { $0.jid == author && $0.nickname == "Ally" }, file: file, line: line)
        XCTAssertTrue(cards.contains { $0.jid == group && $0.kind == .group && $0.privacy == .incognito }, file: file, line: line)
    }

    private func installSearchCallback(_ manager: MessageArchiveManager,
                                       onMessage: @escaping (MessageStorageItem) -> Void) {
        manager.searchResultsQueries.insert(queryID)
        let task = MessageArchiveManager.MAMRequestItem(jid: peer, messageId: nil,
            conversationType: .regular, isContinues: false, searchText: "comment", queryId: queryID,
            afterId: nil, nextPage: nil, prevPage: nil, max: 50, tags: [], start: nil, end: nil,
            purpose: .engineSearchPage, retainsSealedTransportProofUntilBarrier: false)
        manager.upsertCallbackQueueItem(MessageArchiveManager.CallbackQueueItem(
            jid: peer, elementId: queryID, task: task, callback: nil,
            requestCallbacks: .init(onMessage: { row, _ in onMessage(row) })))
    }

    private func archive(_ original: XMPPMessage, leadingForwardedXML: String = "",
                         delayXML: String = "<delay xmlns='urn:xmpp:delay' stamp='2026-10-08T10:00:00Z'/>") throws -> XMPPMessage {
        try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='\(owner)/ios'>
          <m:result xmlns:m='urn:xmpp:mam:2' queryid='\(queryID)' id='mam-route-result'>
            <f:forwarded xmlns:f='urn:xmpp:forward:0'>
              \(leadingForwardedXML)
              \(delayXML)
              \(original.xmlString)
            </f:forwarded>
          </m:result>
        </message>
        """)
    }

    private func carrierWithoutDeliveryTime() throws -> XMPPMessage {
        let message = try carrier()
        message.element(forName: "time", xmlns: "https://xabber.com/protocol/delivery")?.detach()
        return message
    }

    private func carbon(_ original: XMPPMessage, sent: Bool) throws -> XMPPMessage {
        let direction = sent ? "sent" : "received"
        return try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(owner)' to='\(owner)/ios'>
          <c:\(direction) xmlns:c='urn:xmpp:carbons:2'>
            <f:forwarded xmlns:f='urn:xmpp:forward:0'>\(original.xmlString)</f:forwarded>
          </c:\(direction)>
        </message>
        """)
    }

    private func pureSaveCarrier() throws -> XMPPMessage {
        let message = try carrier(outgoing: true, destination: saved)
        message.element(forName: "body", xmlns: "jabber:client")?.stringValue =
            "Alice:\n> Original 😀 & text\n> https://files.example.test/a.pdf\n"
        message.elements(forName: "reference").filter {
            $0.attributeStringValue(forName: "type") == "decoration" ||
                $0.attributeStringValue(forName: "begin") == "72"
        }.forEach { $0.detach() }
        return message
    }

    private func carrier(outgoing: Bool = false, destination: String? = nil) throws -> XMPPMessage {
        // Ranges were calculated independently over the escaped scalar body:
        // Alice fallback 0..<72, Team fallback 72..<94, comment 94..<113.
        try XMPPMessage(xmlString: """
        <message xmlns='jabber:client' from='\(outgoing ? owner : peer)/web'
                 to='\(destination ?? (outgoing ? peer : owner))/ios' type='chat' id='rich-carrier'>
          <origin-id xmlns='urn:xmpp:sid:0' id='rich-carrier'/>
          <stanza-id xmlns='urn:xmpp:sid:0' by='\(owner)' id='carrier-archive'/>
          <time xmlns='https://xabber.com/protocol/delivery' stamp='2026-10-08T10:00:00Z'/>
          <body>Alice:
        &gt; Original 😀 &amp; text
        &gt; https://files.example.test/a.pdf
        Team:
        &gt; Group text
        comment 😀 &amp; own</body>
          <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='0' end='72'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <delay xmlns='urn:xmpp:delay' stamp='2026-10-07T09:00:00Z'/>
              <message xmlns='jabber:client' from='\(author)/phone' to='\(peer)/web' type='chat' id='personal-original'>
                <body>Original 😀 &amp; text
        https://files.example.test/a.pdf</body>
                <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='0' end='8'>
                  <bold xmlns='https://xabber.com/protocol/markup'/>
                </reference>
                <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='22' end='54'>
                  <file-sharing xmlns='https://xabber.com/protocol/files'>
                    <file><name>a.pdf</name><media-type>application/pdf</media-type><size>42</size></file>
                    <sources><uri>https://files.example.test/a.pdf</uri></sources>
                  </file-sharing>
                </reference>
                <opaque xmlns='urn:example:forward-payload'><token><![CDATA[keep <value> & bytes]]></token></opaque>
              </message>
            </forwarded>
          </reference>
          <reference xmlns='https://xabber.com/protocol/references' type='mutable' begin='72' end='94'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <message xmlns='jabber:client' from='\(group)/server' to='\(peer)/web' type='chat' id='group-original'>
                <body>Group text</body>
                <x xmlns='https://xabber.com/protocol/groups'><user id='member-1'>
                  <nickname>Group Member</nickname><jid>bob@example.test</jid><role>admin</role><badge>Helper</badge>
                </user></x>
              </message>
            </forwarded>
          </reference>
          <reference xmlns='https://xabber.com/protocol/references' type='data'>
            <vcard xmlns='urn:ietf:params:xml:ns:vcard-4.0'>
              <fn><text>Alice Snapshot</text></fn><nickname><text>Ally</text></nickname>
              <kind><text>individual</text></kind><impp><uri>xmpp:\(author)</uri></impp>
              <photo><uri>https://files.example.test/alice.png</uri></photo>
            </vcard>
          </reference>
          <reference xmlns='https://xabber.com/protocol/references' type='data'>
            <vcard xmlns='urn:ietf:params:xml:ns:vcard-4.0'>
              <fn><text>Team Snapshot</text></fn><kind><text>group</text></kind>
              <impp><uri>xmpp:\(group)</uri></impp><x-groups-privacy><text>incognito</text></x-groups-privacy>
            </vcard>
          </reference>
          <reference xmlns='https://xabber.com/protocol/references' type='decoration' begin='94' end='113'>
            <bold xmlns='https://xabber.com/protocol/markup'/>
          </reference>
        </message>
        """)
    }
}
