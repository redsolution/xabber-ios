import XCTest
@testable import xabber

final class RedmineIssue50391Tests: XCTestCase {
    // Regression coverage for https://redmine.redsolution.ru/issues/50391
    func testRedmineIssue50391_notificationsRegression() throws {
        // Arrange
        let owner = "romeo@example.org"
        let sentAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2018-04-16T14:00:00Z")
        )
        let archivedMessage = """
        <message>
          <result>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <delay xmlns='urn:xmpp:delay' stamp='2018-04-16T14:00:00Z'/>
              <message from='juliet@example.org/web' to='romeo@example.org' id='message-old'>
                <body>A message sent two days ago</body>
                <stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.org' id='archive-old'/>
              </message>
            </forwarded>
          </result>
        </message>
        """

        // Act
        let preview = try XCTUnwrap(
            PushNotificationArchiveParser.parseArchivedMessage(
                xmlString: archivedMessage,
                owner: owner
            )
        )
        let decodedRoute = try XCTUnwrap(
            PushNotificationRoutePayload(userInfo: preview.route.userInfo())
        )

        // Assert
        XCTAssertEqual(preview.route.owner, owner)
        XCTAssertEqual(preview.route.routeJid, "juliet@example.org")
        XCTAssertEqual(preview.route.stanzaId, "archive-old")
        XCTAssertEqual(preview.body, "A message sent two days ago")
        XCTAssertEqual(
            preview.route.timestamp,
            sentAt.timeIntervalSinceReferenceDate,
            "The notification route must preserve XMPP send time instead of substituting delivery time"
        )
        XCTAssertEqual(
            decodedRoute.timestamp,
            sentAt.timeIntervalSinceReferenceDate,
            "The canonical notification payload must carry the preserved send time"
        )

        let immediatePreview = try XCTUnwrap(
            PushNotificationArchiveParser.parseArchivedMessage(
                xmlString: """
                <message from='juliet@example.org/web' to='romeo@example.org' id='message-live'>
                  <body>A live message without archive delay</body>
                  <stanza-id xmlns='urn:xmpp:sid:0' by='juliet@example.org' id='archive-live'/>
                </message>
                """,
                owner: owner
            )
        )
        XCTAssertNil(
            immediatePreview.route.timestamp,
            "A payload without an authoritative send timestamp must not invent a stale timestamp"
        )
    }
}
