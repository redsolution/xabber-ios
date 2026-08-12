import XCTest
@testable import xabber

@MainActor
final class LastChatsSpecialMessageVisibilityTests: XCTestCase {
    func testRequestAndInviteBannersAreLimitedToOrdinaryRecentChats() {
        XCTAssertTrue(
            LastChatsSpecialMessageVisibilityPolicy.shouldShowSpecialMessageBanners(
                filter: .chats,
                isSearchActive: false
            )
        )

        for filter in [
            LastChatsViewController.Filter.unread,
            .archived,
            .saved
        ] {
            XCTAssertFalse(
                LastChatsSpecialMessageVisibilityPolicy.shouldShowSpecialMessageBanners(
                    filter: filter,
                    isSearchActive: false
                )
            )
        }
    }

    func testRequestAndInviteBannersAreHiddenWhileSearchIsActive() {
        XCTAssertFalse(
            LastChatsSpecialMessageVisibilityPolicy.shouldShowSpecialMessageBanners(
                filter: .chats,
                isSearchActive: true
            )
        )
    }
}
