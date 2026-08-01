import XCTest
@testable import xabber

final class RedmineIssue50392Tests: XCTestCase {
    // Regression coverage for https://redmine.redsolution.ru/issues/50392
    func testRedmineIssue50392_notificationsRegression() throws {
        // Arrange
        let owner = "romeo@example.org"
        let contact = "juliet@example.org"
        let sentCarbon = """
        <message from='romeo@example.org/laptop' to='romeo@example.org/ios' type='chat'>
          <sent xmlns='urn:xmpp:carbons:2'>
            <forwarded xmlns='urn:xmpp:forward:0'>
              <delay xmlns='urn:xmpp:delay' stamp='2018-04-18T12:00:00Z'/>
              <message from='romeo@example.org/laptop' to='juliet@example.org/mobile' type='chat' id='own-carbon-1'>
                <body>Sent while the phone was sleeping</body>
                <stanza-id xmlns='urn:xmpp:sid:0' by='romeo@example.org' id='own-archive-1'/>
              </message>
            </forwarded>
          </sent>
        </message>
        """

        // Act
        let firstPreview = try XCTUnwrap(
            PushNotificationArchiveParser.parseArchivedMessage(
                xmlString: sentCarbon,
                owner: owner
            )
        )
        let repeatedPreview = try XCTUnwrap(
            PushNotificationArchiveParser.parseArchivedMessage(
                xmlString: sentCarbon,
                owner: owner
            )
        )
        let decodedRoute = try XCTUnwrap(
            PushNotificationRoutePayload(userInfo: firstPreview.route.userInfo())
        )

        // Assert
        XCTAssertEqual(firstPreview.route.kind, .message)
        XCTAssertEqual(firstPreview.route.owner, owner)
        XCTAssertEqual(
            firstPreview.route.routeJid,
            contact,
            "A sent carbon must target the remote conversation, not the owner's own JID"
        )
        XCTAssertEqual(firstPreview.route.senderJid, owner)
        XCTAssertEqual(firstPreview.route.messageId, "own-carbon-1")
        XCTAssertEqual(firstPreview.route.stanzaId, "own-archive-1")
        XCTAssertEqual(firstPreview.body, "Sent while the phone was sleeping")
        XCTAssertEqual(decodedRoute, firstPreview.route)
        XCTAssertEqual(
            repeatedPreview.route,
            firstPreview.route,
            "A repeated carbon must retain one stable notification identity and route"
        )
        XCTAssertEqual(repeatedPreview.body, firstPreview.body)
    }
}
