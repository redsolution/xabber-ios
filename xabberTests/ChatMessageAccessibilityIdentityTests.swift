import UIKit
import XCTest
@testable import xabber

@MainActor
final class ChatMessageAccessibilityIdentityTests: XCTestCase {
    private let indexPath = IndexPath(item: 0, section: 0)

    func testNormalConversationCollectionHasIdentityWithoutChangingAccessibilityGrouping() {
        let collection = MessagesCollectionView()
        let ordinary = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        XCTAssertEqual(collection.accessibilityIdentifier, "chat.conversation.messages")
        XCTAssertEqual(collection.isAccessibilityElement, ordinary.isAccessibilityElement)
        XCTAssertEqual(collection.accessibilityTraits, ordinary.accessibilityTraits)
    }

    func testMessageConfigureBindsExactIDAndPrimaryWithoutChangingVoiceOverProperties() {
        let (controller, collection, cell) = fixture()
        defer { _ = controller }
        let message = datasource(id: "36c43080-cca4-4605-a303-79910bbd7d54", primary: "owner|peer|first")
        cell.accessibilityLabel = "Existing label"
        cell.accessibilityValue = "Existing value"
        let isElement = cell.isAccessibilityElement
        let traits = cell.accessibilityTraits
        cell.configure(with: message, at: indexPath, and: collection)
        XCTAssertEqual(cell.accessibilityIdentifier, identifier(message))
        XCTAssertEqual(cell.accessibilityLabel, "Existing label")
        XCTAssertEqual(cell.accessibilityValue, "Existing value")
        XCTAssertEqual(cell.isAccessibilityElement, isElement)
        XCTAssertEqual(cell.accessibilityTraits, traits)
    }

    func testReconfigureUpdatesBothIdentityComponentsAndReuseClearsStaleIdentity() {
        let (controller, collection, cell) = fixture()
        defer { _ = controller }
        let first = datasource(id: "F~jFuDwQ", primary: "first-primary")
        let second = datasource(id: "uT4_rN~v", primary: "second-primary")
        cell.configure(with: first, at: indexPath, and: collection)
        XCTAssertEqual(cell.accessibilityIdentifier, identifier(first))
        cell.reconfigureContent(with: second, at: indexPath, and: collection, changeMask: [.chrome])
        XCTAssertEqual(cell.accessibilityIdentifier, identifier(second))
        cell.prepareForReuse()
        XCTAssertNil(cell.accessibilityIdentifier)
        cell.configure(with: first, at: indexPath, and: collection)
        XCTAssertEqual(cell.accessibilityIdentifier, identifier(first))
    }

    private func identifier(_ message: MessageType) -> String {
        "chat.message.\(Data(message.messageId.utf8).base64EncodedString()).\(Data(message.primary.utf8).base64EncodedString())"
    }

    private func fixture() -> (ChatViewController, MessagesCollectionView, MessageContentCell) {
        let controller = ChatViewController()
        controller.owner = "identity-owner@example.test"; controller.jid = "identity-peer@example.test"
        let collection = MessagesCollectionView()
        collection.messagesDataSource = controller
        return (controller, collection, MessageContentCell(frame: .zero))
    }

    private func datasource(id: String, primary: String) -> ChatViewController.Datasource {
        .init(primary: primary, jid: "identity-peer@example.test", owner: "identity-owner@example.test",
              outgoing: false, sender: Sender(id: "identity-peer@example.test", displayName: "Peer"),
              messageId: id, sentDate: Date(timeIntervalSince1970: 100), editDate: nil,
              kind: .attributedText(NSAttributedString(string: "QA3 exact body")),
              withAuthor: false, withAvatar: false, error: false, errorType: "", canPinMessage: false,
              canEditMessage: false, canDeleteMessage: true, forwards: [], isOutgoing: false, isEdited: false,
              groupchatAuthorRole: "", groupchatAuthorId: "", groupchatAuthorNickname: "", groupchatAuthorBadge: "",
              isHasAttachedMessages: false, isDownloaded: false, state: .read, searchString: nil, errorMetadata: nil,
              burnDate: -1, afterburnInterval: -1, archivedId: "identity-archive", queryIds: nil, isRead: true,
              selectedSearchResultId: nil, isHadHistoryGap: false, tailed: false, isFakeMessage: false,
              images: [], videos: [], locations: [], contacts: [], files: [], audios: [],
              timeMarkerText: NSAttributedString(string: "12:00"), indicator: .none, avatarUrl: nil, attributedAuthor: nil)
    }
}
