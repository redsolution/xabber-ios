import XCTest
@testable import xabber

final class ChatGroupMemberUnreadMetadataRefreshGateTests: XCTestCase {
    func testAuthoritativeMemberIDSkipsInitialAndChangedFallbackEmissions() {
        var gate = ChatGroupMemberUnreadMetadataRefreshGate(
            authoritativeMemberId: "last-chats-member"
        )

        XCTAssertFalse(gate.shouldRefresh(observedMemberId: nil))
        XCTAssertFalse(gate.shouldRefresh(observedMemberId: "realm-member"))
        XCTAssertFalse(gate.shouldRefresh(observedMemberId: "changed-realm-member"))
    }

    func testMissingAuthoritativeMemberIDRefreshesWhenFallbackAppearsAndSkipsDuplicate() {
        var gate = ChatGroupMemberUnreadMetadataRefreshGate(
            authoritativeMemberId: nil
        )

        XCTAssertFalse(gate.shouldRefresh(observedMemberId: nil))
        XCTAssertFalse(gate.shouldRefresh(observedMemberId: ""))
        XCTAssertTrue(gate.shouldRefresh(observedMemberId: "realm-member"))
        XCTAssertFalse(gate.shouldRefresh(observedMemberId: "realm-member"))
    }

    func testMissingAuthoritativeMemberIDRefreshesWhenFallbackChangesOrDisappears() {
        var gate = ChatGroupMemberUnreadMetadataRefreshGate(
            authoritativeMemberId: nil
        )

        XCTAssertTrue(gate.shouldRefresh(observedMemberId: "realm-member-a"))
        XCTAssertTrue(gate.shouldRefresh(observedMemberId: "realm-member-b"))
        XCTAssertTrue(gate.shouldRefresh(observedMemberId: nil))
        XCTAssertFalse(gate.shouldRefresh(observedMemberId: ""))
    }
}
