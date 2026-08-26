//
//  ChatNavigationCancellationTests.swift
//  xabberTests
//

import XCTest
@testable import xabber

final class ChatNavigationCancellationTests: XCTestCase {
    func testScheduledDisappearanceReappearanceRemainsRollbackAfterInteractionEnds() {
        XCTAssertTrue(
            ChatNavigationTransitionMutationPolicy.isCancelledReappearance(
                didRunDisappearanceCleanup: false,
                didScheduleDisappearanceCleanup: true,
                didCancelDisappearanceTransition: false,
                hasRegisteredChatObservers: true
            ),
            "scheduled cleanup is the ownership receipt while UIKit is between interaction end and transition completion"
        )
        XCTAssertFalse(
            ChatNavigationTransitionMutationPolicy.isCancelledReappearance(
                didRunDisappearanceCleanup: true,
                didScheduleDisappearanceCleanup: false,
                didCancelDisappearanceTransition: false,
                hasRegisteredChatObservers: false
            ),
            "a controller returning after terminal cleanup must perform its ordinary appearance lifecycle"
        )
    }
}
