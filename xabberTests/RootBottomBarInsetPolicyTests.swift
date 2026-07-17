//
//  RootBottomBarInsetPolicyTests.swift
//  xabberTests
//

import XCTest
import UIKit
@testable import xabber

final class RootBottomBarInsetPolicyTests: XCTestCase {
    func testNoOverlayRestoresBaselineBottomInsets() {
        let fixture = makeCoordinatorFixture(contentBottom: 8, indicatorBottom: 5)

        fixture.coordinator.apply(
            to: fixture.scrollView,
            in: fixture.container,
            overlays: [fixture.overlay]
        )
        fixture.overlay.isHidden = true
        fixture.coordinator.apply(
            to: fixture.scrollView,
            in: fixture.container,
            overlays: [fixture.overlay]
        )

        XCTAssertEqual(fixture.scrollView.contentInset.bottom, 8, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.verticalScrollIndicatorInsets.bottom, 5, accuracy: 0.001)
        XCTAssertEqual(fixture.coordinator.appliedBottomContribution, 0, accuracy: 0.001)
    }

    func testSafeAreaZeroComputesOverlayClearance() {
        let contribution = RootBottomBarInsetPolicy.requiredBottomContribution(
            containerMaxY: 844,
            visibleOverlayFrames: [CGRect(x: 0, y: 796, width: 390, height: 44)],
            systemBottomContribution: 0,
            baselineBottomInset: 0
        )

        XCTAssertEqual(contribution, 60, accuracy: 0.001)
    }

    func testSafeAreaThirtyFourSubtractsAutomaticSystemContribution() {
        let contribution = RootBottomBarInsetPolicy.requiredBottomContribution(
            containerMaxY: 844,
            visibleOverlayFrames: [CGRect(x: 0, y: 762, width: 390, height: 44)],
            systemBottomContribution: 34,
            baselineBottomInset: 0
        )

        XCTAssertEqual(contribution, 60, accuracy: 0.001)
    }

    func testCollapsedBarLeavesTwelvePointClearanceAboveOverlay() {
        let overlayMinY: CGFloat = 796
        let contribution = RootBottomBarInsetPolicy.requiredBottomContribution(
            containerMaxY: 844,
            visibleOverlayFrames: [CGRect(x: 0, y: overlayMinY, width: 390, height: 44)],
            systemBottomContribution: 0,
            baselineBottomInset: 0
        )

        XCTAssertEqual(844 - contribution, overlayMinY - RootBottomBarInsetPolicy.clearance, accuracy: 0.001)
    }

    func testKeyboardRaisedSearchUsesActualOverlayMinY() {
        let contribution = RootBottomBarInsetPolicy.requiredBottomContribution(
            containerMaxY: 844,
            visibleOverlayFrames: [CGRect(x: 0, y: 500, width: 390, height: 44)],
            systemBottomContribution: 34,
            baselineBottomInset: 0
        )

        XCTAssertEqual(contribution, 322, accuracy: 0.001)
    }

    func testTopmostOfMultipleVisibleOverlaysWins() {
        let contribution = RootBottomBarInsetPolicy.requiredBottomContribution(
            containerMaxY: 844,
            visibleOverlayFrames: [
                CGRect(x: 0, y: 796, width: 390, height: 44),
                CGRect(x: 0, y: 620, width: 390, height: 44)
            ],
            systemBottomContribution: 0,
            baselineBottomInset: 0
        )

        XCTAssertEqual(contribution, 236, accuracy: 0.001)
    }

    func testHiddenOverlayDoesNotReserveSpace() {
        let fixture = makeCoordinatorFixture()
        fixture.overlay.isHidden = true

        fixture.coordinator.apply(
            to: fixture.scrollView,
            in: fixture.container,
            overlays: [fixture.overlay]
        )

        XCTAssertEqual(fixture.scrollView.contentInset.bottom, 0, accuracy: 0.001)
        XCTAssertEqual(fixture.coordinator.appliedBottomContribution, 0, accuracy: 0.001)
    }

    func testExistingTopAndSideInsetsArePreserved() {
        let fixture = makeCoordinatorFixture()
        fixture.scrollView.contentInset = UIEdgeInsets(top: 11, left: 13, bottom: 0, right: 17)
        fixture.scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: 19, left: 23, bottom: 0, right: 29)

        fixture.coordinator.apply(
            to: fixture.scrollView,
            in: fixture.container,
            overlays: [fixture.overlay]
        )

        XCTAssertEqual(fixture.scrollView.contentInset.top, 11, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.contentInset.left, 13, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.contentInset.right, 17, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.verticalScrollIndicatorInsets.top, 19, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.verticalScrollIndicatorInsets.left, 23, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.verticalScrollIndicatorInsets.right, 29, accuracy: 0.001)
    }

    func testExistingBaselineBottomInsetIsPreserved() {
        let fixture = makeCoordinatorFixture(contentBottom: 8, indicatorBottom: 5)

        fixture.coordinator.apply(
            to: fixture.scrollView,
            in: fixture.container,
            overlays: [fixture.overlay]
        )

        XCTAssertEqual(fixture.coordinator.appliedBottomContribution, 52, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.contentInset.bottom, 60, accuracy: 0.001)
        XCTAssertEqual(fixture.scrollView.verticalScrollIndicatorInsets.bottom, 57, accuracy: 0.001)
    }

    func testAtBottomMovesToNewMaximumOffsetAfterInsetIncrease() {
        let result = RootBottomBarInsetPolicy.adjustedContentOffsetY(
            currentY: 1_000,
            oldMinimumY: -20,
            oldMaximumY: 1_000,
            newMinimumY: -20,
            newMaximumY: 1_200
        )

        XCTAssertEqual(result, 1_200, accuracy: 0.001)
    }

    func testAtBottomMovesToNewMaximumOffsetAfterInsetDecrease() {
        let result = RootBottomBarInsetPolicy.adjustedContentOffsetY(
            currentY: 1_200,
            oldMinimumY: -20,
            oldMaximumY: 1_200,
            newMinimumY: -20,
            newMaximumY: 1_000
        )

        XCTAssertEqual(result, 1_000, accuracy: 0.001)
    }

    func testAwayFromBottomKeepsContentOffset() {
        let result = RootBottomBarInsetPolicy.adjustedContentOffsetY(
            currentY: 420,
            oldMinimumY: -20,
            oldMaximumY: 1_000,
            newMinimumY: -20,
            newMaximumY: 1_200
        )

        XCTAssertEqual(result, 420, accuracy: 0.001)
    }

    func testShortContentOffsetIsClampedToValidRange() {
        let result = RootBottomBarInsetPolicy.adjustedContentOffsetY(
            currentY: 120,
            oldMinimumY: -88,
            oldMaximumY: -20,
            newMinimumY: -88,
            newMaximumY: -40
        )

        XCTAssertEqual(result, -40, accuracy: 0.001)
    }

    func testRepeatedIdenticalUpdateIsIdempotent() {
        let fixture = makeCoordinatorFixture()
        fixture.scrollView.contentSize.height = 1_600
        fixture.scrollView.contentOffset.y = 420

        fixture.coordinator.apply(
            to: fixture.scrollView,
            in: fixture.container,
            overlays: [fixture.overlay]
        )
        let firstInset = fixture.scrollView.contentInset
        let firstIndicatorInset = fixture.scrollView.verticalScrollIndicatorInsets
        let firstOffset = fixture.scrollView.contentOffset

        fixture.coordinator.apply(
            to: fixture.scrollView,
            in: fixture.container,
            overlays: [fixture.overlay]
        )

        XCTAssertEqual(fixture.scrollView.contentInset, firstInset)
        XCTAssertEqual(fixture.scrollView.verticalScrollIndicatorInsets, firstIndicatorInset)
        XCTAssertEqual(fixture.scrollView.contentOffset, firstOffset)
    }

    func testVerticalIndicatorReceivesSameOverlayContribution() {
        let fixture = makeCoordinatorFixture(contentBottom: 8, indicatorBottom: 5)

        fixture.coordinator.apply(
            to: fixture.scrollView,
            in: fixture.container,
            overlays: [fixture.overlay]
        )

        XCTAssertEqual(
            fixture.scrollView.contentInset.bottom - 8,
            fixture.scrollView.verticalScrollIndicatorInsets.bottom - 5,
            accuracy: 0.001
        )
    }

    private func makeCoordinatorFixture(
        contentBottom: CGFloat = 0,
        indicatorBottom: CGFloat = 0
    ) -> (
        coordinator: BottomOverlayInsetCoordinator,
        container: UIView,
        scrollView: UIScrollView,
        overlay: UIView
    ) {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scrollView = UIScrollView(frame: container.bounds)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset.bottom = contentBottom
        scrollView.verticalScrollIndicatorInsets.bottom = indicatorBottom
        container.addSubview(scrollView)

        let overlay = UIView(frame: CGRect(x: 0, y: 796, width: 390, height: 44))
        container.addSubview(overlay)

        return (BottomOverlayInsetCoordinator(), container, scrollView, overlay)
    }
}
