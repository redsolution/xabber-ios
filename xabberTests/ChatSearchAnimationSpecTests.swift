//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//

import XCTest
@testable import xabber

final class ChatSearchAnimationSpecTests: XCTestCase {
    func testFloatingButtonsUseReferenceSpringScaleAndAlpha() throws {
        let transition = ChatSearchAnimationSpec.production.floatingButtons
        let scale = try XCTUnwrap(transition.scale)
        let alpha = try XCTUnwrap(transition.alpha)

        XCTAssertEqual(scale.from, 0.2, accuracy: 0.0001)
        XCTAssertEqual(scale.to, 1, accuracy: 0.0001)
        XCTAssertEqual(alpha.from, 0, accuracy: 0.0001)
        XCTAssertEqual(alpha.to, 1, accuracy: 0.0001)
        XCTAssertEqual(scale.timing.duration, 0.30, accuracy: 0.0001)
        XCTAssertEqual(alpha.timing, scale.timing)
        XCTAssertEqual(
            scale.timing.curve,
            .spring(.init(dampingRatio: 0.78, initialVelocity: 0.2))
        )
    }

    func testListPresentationUsesIndependentScaleAndBlurChannels() throws {
        let transition = ChatSearchAnimationSpec.production.list.presentation
        let scale = try XCTUnwrap(transition.scale)
        let blur = try XCTUnwrap(transition.blurRadius)

        XCTAssertEqual(scale.from, 0.95, accuracy: 0.0001)
        XCTAssertEqual(scale.to, 1, accuracy: 0.0001)
        XCTAssertEqual(scale.timing.duration, 0.40, accuracy: 0.0001)
        XCTAssertEqual(
            scale.timing.curve,
            .spring(.init(dampingRatio: 0.86, initialVelocity: 0.15))
        )
        XCTAssertEqual(blur.from, 30, accuracy: 0.0001)
        XCTAssertEqual(blur.to, 0, accuracy: 0.0001)
        XCTAssertEqual(blur.timing.duration, 0.20, accuracy: 0.0001)
        XCTAssertEqual(blur.timing.curve, .easeOut)
    }

    func testListDismissalUsesReferenceScaleAndBlurDuration() throws {
        let transition = ChatSearchAnimationSpec.production.list.dismissal
        let scale = try XCTUnwrap(transition.scale)
        let blur = try XCTUnwrap(transition.blurRadius)

        XCTAssertEqual(scale.from, 1, accuracy: 0.0001)
        XCTAssertEqual(scale.to, 0.95, accuracy: 0.0001)
        XCTAssertEqual(blur.from, 0, accuracy: 0.0001)
        XCTAssertEqual(blur.to, 30, accuracy: 0.0001)
        XCTAssertEqual(scale.timing.duration, 0.30, accuracy: 0.0001)
        XCTAssertEqual(blur.timing.duration, 0.30, accuracy: 0.0001)
        XCTAssertEqual(scale.timing.curve, .easeInOut)
        XCTAssertEqual(blur.timing.curve, .easeInOut)
    }

    func testCalendarDimAndSheetUseSharedReferenceTiming() throws {
        let calendar = ChatSearchAnimationSpec.production.calendar
        let dimIn = try XCTUnwrap(calendar.dimPresentation.alpha)
        let sheetIn = try XCTUnwrap(calendar.sheetPresentation.verticalOffsetFraction)
        let dimOut = try XCTUnwrap(calendar.dimDismissal.alpha)
        let sheetOut = try XCTUnwrap(calendar.sheetDismissal.verticalOffsetFraction)

        XCTAssertEqual(dimIn.from, 0, accuracy: 0.0001)
        XCTAssertEqual(dimIn.to, 1, accuracy: 0.0001)
        XCTAssertEqual(sheetIn.from, 1, accuracy: 0.0001)
        XCTAssertEqual(sheetIn.to, 0, accuracy: 0.0001)
        XCTAssertEqual(dimIn.timing.duration, 0.40, accuracy: 0.0001)
        XCTAssertEqual(sheetIn.timing, dimIn.timing)
        XCTAssertEqual(
            sheetIn.timing.curve,
            .spring(.init(dampingRatio: 0.86, initialVelocity: 0.15))
        )
        XCTAssertEqual(dimOut.from, 1, accuracy: 0.0001)
        XCTAssertEqual(dimOut.to, 0, accuracy: 0.0001)
        XCTAssertEqual(sheetOut.from, 0, accuracy: 0.0001)
        XCTAssertEqual(sheetOut.to, 1, accuracy: 0.0001)
        XCTAssertEqual(dimOut.timing.duration, 0.30, accuracy: 0.0001)
        XCTAssertEqual(sheetOut.timing.duration, 0.30, accuracy: 0.0001)
    }

    func testMonthSwipeUsesSemanticDirectionAndMirrorsInRTL() {
        let swipe = ChatSearchAnimationSpec.production.monthSwipe

        XCTAssertEqual(swipe.timing.duration, 0.30, accuracy: 0.0001)
        XCTAssertEqual(swipe.timing.curve, .easeInOut)
        XCTAssertEqual(swipe.mode, .horizontalSlide)
        XCTAssertEqual(
            swipe.contentTravelDirection(for: .next, layoutDirection: .leftToRight),
            .left
        )
        XCTAssertEqual(
            swipe.contentTravelDirection(for: .previous, layoutDirection: .leftToRight),
            .right
        )
        XCTAssertEqual(
            swipe.contentTravelDirection(for: .next, layoutDirection: .rightToLeft),
            .right
        )
        XCTAssertEqual(
            swipe.contentTravelDirection(for: .previous, layoutDirection: .rightToLeft),
            .left
        )
    }

    func testReduceMotionReplacesTransformsAndBlurWithShortCrossfades() throws {
        let resolved = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: true, reduceTransparency: false)
        )

        XCTAssertTrue(resolved.isReducedMotion)
        XCTAssertNil(resolved.floatingButtons.scale)
        XCTAssertNil(resolved.list.presentation.scale)
        XCTAssertNil(resolved.list.presentation.blurRadius)
        XCTAssertNil(resolved.calendar.sheetPresentation.verticalOffsetFraction)
        XCTAssertEqual(resolved.floatingButtons.alpha?.timing.duration, 0.15)
        XCTAssertEqual(resolved.list.presentation.alpha?.timing.duration, 0.15)
        XCTAssertEqual(resolved.calendar.sheetPresentation.alpha?.timing.duration, 0.15)
        XCTAssertEqual(resolved.monthSwipe.mode, .crossfade)
        XCTAssertEqual(resolved.monthSwipe.timing.duration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(
            resolved.monthSwipe.contentTravelDirection(
                for: .next,
                layoutDirection: .leftToRight
            ),
            .none
        )
    }

    func testReduceTransparencyDisablesBlurAndUsesOpaqueSystemTreatment() {
        let resolved = ChatSearchAnimationSpec.production.resolved(
            for: .init(reduceMotion: false, reduceTransparency: true)
        )

        XCTAssertFalse(resolved.isReducedMotion)
        XCTAssertEqual(resolved.backgroundTreatment, .opaqueSystemMaterial)
        XCTAssertNil(resolved.list.presentation.blurRadius)
        XCTAssertNil(resolved.list.dismissal.blurRadius)
        XCTAssertNotNil(resolved.list.presentation.scale)
    }

    func testDefaultUsesOnlyPublicVisualEffectTreatment() {
        XCTAssertEqual(
            ChatSearchAnimationSpec.production.backgroundTreatment,
            .publicVisualEffect
        )
    }

    func testEveryTransitionRequiresFinalStateApplication() {
        let spec = ChatSearchAnimationSpec.production
        let transitions = [
            spec.floatingButtons,
            spec.list.presentation,
            spec.list.dismissal,
            spec.calendar.dimPresentation,
            spec.calendar.sheetPresentation,
            spec.calendar.dimDismissal,
            spec.calendar.sheetDismissal
        ]

        XCTAssertTrue(transitions.allSatisfy { $0.completionPolicy == .applyFinalState })
    }

    func testImmediateSpecPreservesEndpointsWithZeroDurations() {
        let spec = ChatSearchAnimationSpec.immediate
        let timings = [
            spec.floatingButtons.scale?.timing,
            spec.floatingButtons.alpha?.timing,
            spec.list.presentation.scale?.timing,
            spec.list.presentation.blurRadius?.timing,
            spec.list.dismissal.scale?.timing,
            spec.list.dismissal.blurRadius?.timing,
            spec.calendar.dimPresentation.alpha?.timing,
            spec.calendar.sheetPresentation.verticalOffsetFraction?.timing,
            spec.calendar.dimDismissal.alpha?.timing,
            spec.calendar.sheetDismissal.verticalOffsetFraction?.timing,
            spec.monthSwipe.timing
        ].compactMap { $0 }

        XCTAssertTrue(timings.allSatisfy { $0.duration == 0 })
        XCTAssertEqual(spec.floatingButtons.scale?.from, 0.2)
        XCTAssertEqual(spec.list.presentation.scale?.from, 0.95)
        XCTAssertEqual(spec.calendar.sheetPresentation.verticalOffsetFraction?.from, 1)
    }
}
