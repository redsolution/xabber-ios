import XCTest
@testable import xabber

final class ChatGroupMessageChromePolicyTests: XCTestCase {
    private let owner = "owner@example.com"
    private let groupJid = "room@example.com"

    func testSingleIncomingGroupMessageDrawsAuthorAvatarAndReservesAvatarSpace() throws {
        let controller = makeController()
        let message = makeMessage(primary: "a1", userId: "user-a", nickname: "Alexey")

        let row = mappedRows(controller, messages: [message]).row("a1")

        XCTAssertTrue(row.withAuthor)
        XCTAssertTrue(row.withAvatar)
        XCTAssertTrue(row.reservesAvatarSpace)
        XCTAssertEqual(row.avatarUrl, "https://avatars.example.com/user-a.png")
    }

    func testIncomingSameAuthorSeriesDrawsAuthorOnOldestAndAvatarOnNewest() throws {
        let controller = makeController()
        let messages = [
            makeMessage(primary: "a1", userId: "user-a", nickname: "Alexey", timestamp: 100),
            makeMessage(primary: "a2", userId: "user-a", nickname: "Alexey", timestamp: 110),
            makeMessage(primary: "a3", userId: "user-a", nickname: "Alexey", timestamp: 120)
        ]

        let rows = mappedRows(controller, messages: messages)

        XCTAssertEqual(rows.realRows.map(\.primary), ["a1", "a2", "a3"])
        XCTAssertEqual(rows.realRows.map(\.withAuthor), [true, false, false])
        XCTAssertEqual(rows.realRows.map(\.withAvatar), [false, false, true])
        XCTAssertEqual(rows.realRows.map(\.reservesAvatarSpace), [true, true, true])
        XCTAssertNil(rows.row("a1").avatarUrl)
        XCTAssertNil(rows.row("a2").avatarUrl)
        XCTAssertEqual(rows.row("a3").avatarUrl, "https://avatars.example.com/user-a.png")
    }

    func testOutgoingGroupMessageDoesNotDrawAuthorAvatarOrReserveAvatarSpace() throws {
        let controller = makeController()
        let message = makeMessage(
            primary: "outgoing",
            userId: "owner-user",
            nickname: "Me",
            outgoing: true
        )

        let row = mappedRows(controller, messages: [message]).row("outgoing")

        XCTAssertFalse(row.withAuthor)
        XCTAssertFalse(row.withAvatar)
        XCTAssertFalse(row.reservesAvatarSpace)
        XCTAssertNil(row.avatarUrl)
    }

    func testIncomingSeriesRestartsAfterOutgoingAndDifferentParticipant() throws {
        let controller = makeController()
        let messages = [
            makeMessage(primary: "a1", userId: "user-a", nickname: "Alexey", timestamp: 100),
            makeMessage(primary: "outgoing", userId: "owner-user", nickname: "Me", outgoing: true, timestamp: 110),
            makeMessage(primary: "a2", userId: "user-a", nickname: "Alexey", timestamp: 120),
            makeMessage(primary: "b1", userId: "user-b", nickname: "Boris", timestamp: 130),
            makeMessage(primary: "a3", userId: "user-a", nickname: "Alexey", timestamp: 140)
        ]

        let rows = mappedRows(controller, messages: messages)

        XCTAssertEqual(rows.row("a1").withAuthor, true)
        XCTAssertEqual(rows.row("a1").withAvatar, true)
        XCTAssertEqual(rows.row("a2").withAuthor, true)
        XCTAssertEqual(rows.row("a2").withAvatar, true)
        XCTAssertEqual(rows.row("b1").withAuthor, true)
        XCTAssertEqual(rows.row("b1").withAvatar, true)
        XCTAssertEqual(rows.row("a3").withAuthor, true)
        XCTAssertEqual(rows.row("a3").withAvatar, true)
        XCTAssertEqual(["a1", "a2", "b1", "a3"].map { rows.row($0).reservesAvatarSpace }, [true, true, true, true])
        XCTAssertFalse(rows.row("outgoing").reservesAvatarSpace)
    }

    func testDateChangeBreaksIncomingSameAuthorSeries() throws {
        let controller = makeController()
        let dayOne = Date(timeIntervalSince1970: 1_700_000_000)
        let dayTwo = dayOne.addingTimeInterval(24 * 60 * 60)
        let messages = [
            makeMessage(primary: "a1", userId: "user-a", nickname: "Alexey", date: dayOne),
            makeMessage(primary: "a2", userId: "user-a", nickname: "Alexey", date: dayTwo)
        ]

        let rows = mappedRows(controller, messages: messages)

        XCTAssertTrue(rows.row("a1").withAuthor)
        XCTAssertTrue(rows.row("a1").withAvatar)
        XCTAssertTrue(rows.row("a2").withAuthor)
        XCTAssertTrue(rows.row("a2").withAvatar)
        XCTAssertEqual(rows.realRows.map(\.reservesAvatarSpace), [true, true])
    }

    private func makeController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = owner
        controller.jid = groupJid
        controller.conversationType = .group
        controller.ownerSender = Sender(id: owner, displayName: "Owner")
        controller.opponentSender = Sender(id: groupJid, displayName: groupJid)
        controller.showSkeletonObserver.accept(false)
        return controller
    }

    private func makeMessage(
        primary: String,
        userId: String,
        nickname: String,
        outgoing: Bool = false,
        timestamp: TimeInterval = 100,
        date: Date? = nil
    ) -> MessageStorageItem {
        let sentDate = date ?? Date(timeIntervalSince1970: timestamp)
        let message = MessageStorageItem()
        message.primary = primary
        message.owner = owner
        message.opponent = groupJid
        message.conversationType = .group
        message.messageId = primary
        message.archivedId = "archive-\(primary)"
        message.body = "Message \(primary)"
        message.legacyBody = message.body
        message.date = sentDate
        message.sentDate = sentDate
        message.outgoing = outgoing
        message.state = outgoing ? .sended : .read
        message.isRead = true

        let card = GroupchatUserStorageItem()
        card.primary = "\(primary)-card"
        card.owner = owner
        card.groupchatId = groupJid
        card.userId = userId
        card.jid = outgoing ? owner : "\(userId)@example.com"
        card.nickname = nickname
        card.avatarURI = "https://avatars.example.com/\(userId).png"
        message.groupchatCard = card

        return message
    }

    private func mappedRows(
        _ controller: ChatViewController,
        messages: [MessageStorageItem]
    ) -> MappedRows {
        MappedRows(rows: controller.mapDataset(dataset: messages))
    }
}

private struct MappedRows {
    let rows: [ChatViewController.Datasource]

    var realRows: [ChatViewController.Datasource] {
        rows.filter { !$0.isFakeMessage }
    }

    func row(
        _ primary: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ChatViewController.Datasource {
        guard let row = realRows.first(where: { $0.primary == primary }) else {
            XCTFail("Expected mapped row \(primary)", file: file, line: line)
            fatalError("Missing mapped row \(primary)")
        }
        return row
    }
}
