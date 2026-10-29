import XCTest
@testable import xabber

final class ChatOpeningSavedPositionRegressionTests: XCTestCase {
    func testMissingArchiveEdgeDoesNotAuthorizeOldSavedPosition() {
        XCTAssertEqual(decision(currentArchiveEdge: nil, savedArchiveEdge: nil), .bottom)
    }

    func testEmptyArchiveEdgeDoesNotAuthorizeOldSavedPosition() {
        for edge in ["", " ", "\n\t"] {
            XCTAssertEqual(decision(currentArchiveEdge: edge, savedArchiveEdge: edge), .bottom)
        }
    }

    func testEmptyLastMessageEdgeDoesNotAuthorizeOldSavedPosition() {
        for edge in ["", " ", "\n\t"] {
            XCTAssertEqual(decision(currentMessageEdge: edge, savedMessageEdge: edge), .bottom)
        }
    }

    func testCompleteMatchingEdgesRestoreSavedPosition() {
        guard case .open(let request) = decision() else {
            return XCTFail("A saved position with both current edge fingerprints must be restored")
        }
        XCTAssertEqual(request.source, .savedVisiblePosition)
        XCTAssertEqual(request.anchor.messagePrimary, "saved-old-row")
        XCTAssertFalse(request.markReadOnVisible)
    }

    func testChangedEdgesRejectSavedPosition() {
        XCTAssertEqual(decision(currentMessageEdge: "new-message"), .bottom)
        XCTAssertEqual(decision(currentArchiveEdge: "new-archive-edge"), .bottom)
    }

    func testRuntimeOnlyUnreadRejectsOtherwiseValidSavedPosition() {
        XCTAssertEqual(decision(unread: 2), .bottom)
    }

    func testPositiveServerUnreadOutranksSavedPosition() {
        guard case .open(let request) = decision(unread: 2, syncUnread: 2, boundary: "opaque-boundary") else {
            return XCTFail("A positive server unread boundary must win")
        }
        XCTAssertEqual(request.source, .initialUnreadBoundary)
        XCTAssertEqual(request.targetResolution, .firstIncomingAfterBoundary("opaque-boundary"))
    }

    func testBlankUnreadBoundaryDoesNotCreateAnArchiveTarget() {
        for boundary in ["", " ", "\n\t"] {
            XCTAssertEqual(decision(unread: 2, syncUnread: 2, boundary: boundary), .bottom)
        }
    }

    private func decision(
        currentMessageEdge: String = "current-message",
        savedMessageEdge: String? = "current-message",
        currentArchiveEdge: String? = "opaque-current-edge",
        savedArchiveEdge: String? = "opaque-current-edge",
        unread: Int = 0,
        syncUnread: Int = 0,
        boundary: String? = nil
    ) -> ChatInitialPositionPolicy.Decision {
        let state = ChatInitialPositionPolicy.ChatState(
            owner: "owner@example.org", jid: "peer@example.org", conversationType: .regular,
            unread: unread, syncUnreadCount: syncUnread, syncUnreadAfterId: boundary,
            lastReadId: nil, lastMessageId: currentMessageEdge,
            syncSnapshotLastArchiveId: currentArchiveEdge, messageDate: .distantFuture,
            savedPosition: ChatSavedVisiblePosition(messagePrimary: "saved-old-row",
                archivedId: "saved-mam-cursor", messageId: "saved-message", sourceDate: .distantPast),
            savedAtLastMessageId: savedMessageEdge,
            savedAtSnapshotLastArchiveId: savedArchiveEdge
        )
        return ChatInitialPositionPolicy.decision(for: state, explicitRequest: nil)
    }
}
