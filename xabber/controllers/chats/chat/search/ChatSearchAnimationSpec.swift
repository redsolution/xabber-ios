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

import Foundation

struct ChatSearchAnimationSpec: Equatable, Sendable {
    struct Spring: Equatable, Sendable {
        let dampingRatio: Double
        let initialVelocity: Double
    }

    enum Curve: Equatable, Sendable {
        case spring(Spring)
        case easeOut
        case easeInOut
        case linear
    }

    struct Timing: Equatable, Sendable {
        let duration: TimeInterval
        let curve: Curve

        fileprivate func replacingDuration(with duration: TimeInterval) -> Timing {
            Timing(duration: duration, curve: curve)
        }
    }

    struct ScalarTransition: Equatable, Sendable {
        let from: Double
        let to: Double
        let timing: Timing

        fileprivate func replacingDuration(with duration: TimeInterval) -> ScalarTransition {
            ScalarTransition(
                from: from,
                to: to,
                timing: timing.replacingDuration(with: duration)
            )
        }
    }

    enum CompletionPolicy: Equatable, Sendable {
        case applyFinalState
    }

    struct Transition: Equatable, Sendable {
        let scale: ScalarTransition?
        let alpha: ScalarTransition?
        let blurRadius: ScalarTransition?
        let verticalOffsetFraction: ScalarTransition?
        let completionPolicy: CompletionPolicy

        init(
            scale: ScalarTransition? = nil,
            alpha: ScalarTransition? = nil,
            blurRadius: ScalarTransition? = nil,
            verticalOffsetFraction: ScalarTransition? = nil,
            completionPolicy: CompletionPolicy = .applyFinalState
        ) {
            self.scale = scale
            self.alpha = alpha
            self.blurRadius = blurRadius
            self.verticalOffsetFraction = verticalOffsetFraction
            self.completionPolicy = completionPolicy
        }

        fileprivate func replacingDuration(with duration: TimeInterval) -> Transition {
            Transition(
                scale: scale?.replacingDuration(with: duration),
                alpha: alpha?.replacingDuration(with: duration),
                blurRadius: blurRadius?.replacingDuration(with: duration),
                verticalOffsetFraction: verticalOffsetFraction?.replacingDuration(with: duration),
                completionPolicy: completionPolicy
            )
        }

        fileprivate func withoutBlur() -> Transition {
            Transition(
                scale: scale,
                alpha: alpha,
                blurRadius: nil,
                verticalOffsetFraction: verticalOffsetFraction,
                completionPolicy: completionPolicy
            )
        }
    }

    struct ListTransitions: Equatable, Sendable {
        let presentation: Transition
        let dismissal: Transition
    }

    struct CalendarTransitions: Equatable, Sendable {
        let dimPresentation: Transition
        let sheetPresentation: Transition
        let dimDismissal: Transition
        let sheetDismissal: Transition
    }

    enum SemanticMonthDirection: Equatable, Sendable {
        case previous
        case next
    }

    enum LayoutDirection: Equatable, Sendable {
        case leftToRight
        case rightToLeft
    }

    enum HorizontalTravelDirection: Equatable, Sendable {
        case left
        case right
        case none
    }

    struct MonthSwipe: Equatable, Sendable {
        enum Mode: Equatable, Sendable {
            case horizontalSlide
            case crossfade
        }

        let timing: Timing
        let mode: Mode

        func contentTravelDirection(
            for semanticDirection: SemanticMonthDirection,
            layoutDirection: LayoutDirection
        ) -> HorizontalTravelDirection {
            guard mode == .horizontalSlide else {
                return .none
            }
            switch (semanticDirection, layoutDirection) {
            case (.next, .leftToRight), (.previous, .rightToLeft):
                return .left
            case (.previous, .leftToRight), (.next, .rightToLeft):
                return .right
            }
        }
    }

    struct AccessibilityPreferences: Equatable, Sendable {
        let reduceMotion: Bool
        let reduceTransparency: Bool
    }

    enum BackgroundTreatment: Equatable, Sendable {
        case publicVisualEffect
        case opaqueSystemMaterial
    }

    let floatingButtons: Transition
    let list: ListTransitions
    let calendar: CalendarTransitions
    let monthSwipe: MonthSwipe
    let backgroundTreatment: BackgroundTreatment
    let isReducedMotion: Bool

    init(
        floatingButtons: Transition,
        list: ListTransitions,
        calendar: CalendarTransitions,
        monthSwipe: MonthSwipe,
        backgroundTreatment: BackgroundTreatment,
        isReducedMotion: Bool = false
    ) {
        self.floatingButtons = floatingButtons
        self.list = list
        self.calendar = calendar
        self.monthSwipe = monthSwipe
        self.backgroundTreatment = backgroundTreatment
        self.isReducedMotion = isReducedMotion
    }

    static let production: ChatSearchAnimationSpec = {
        let floatingSpring = Timing(
            duration: 0.30,
            curve: .spring(Spring(dampingRatio: 0.78, initialVelocity: 0.2))
        )
        let listSpring = Timing(
            duration: 0.40,
            curve: .spring(Spring(dampingRatio: 0.86, initialVelocity: 0.15))
        )
        let listBlurIn = Timing(duration: 0.20, curve: .easeOut)
        let listOut = Timing(duration: 0.30, curve: .easeInOut)
        let calendarSpring = Timing(
            duration: 0.40,
            curve: .spring(Spring(dampingRatio: 0.86, initialVelocity: 0.15))
        )
        let calendarOut = Timing(duration: 0.30, curve: .easeInOut)

        return ChatSearchAnimationSpec(
            floatingButtons: Transition(
                scale: ScalarTransition(from: 0.2, to: 1, timing: floatingSpring),
                alpha: ScalarTransition(from: 0, to: 1, timing: floatingSpring)
            ),
            list: ListTransitions(
                presentation: Transition(
                    scale: ScalarTransition(from: 0.95, to: 1, timing: listSpring),
                    blurRadius: ScalarTransition(from: 30, to: 0, timing: listBlurIn)
                ),
                dismissal: Transition(
                    scale: ScalarTransition(from: 1, to: 0.95, timing: listOut),
                    blurRadius: ScalarTransition(from: 0, to: 30, timing: listOut)
                )
            ),
            calendar: CalendarTransitions(
                dimPresentation: Transition(
                    alpha: ScalarTransition(from: 0, to: 1, timing: calendarSpring)
                ),
                sheetPresentation: Transition(
                    verticalOffsetFraction: ScalarTransition(
                        from: 1,
                        to: 0,
                        timing: calendarSpring
                    )
                ),
                dimDismissal: Transition(
                    alpha: ScalarTransition(from: 1, to: 0, timing: calendarOut)
                ),
                sheetDismissal: Transition(
                    verticalOffsetFraction: ScalarTransition(
                        from: 0,
                        to: 1,
                        timing: calendarOut
                    )
                )
            ),
            monthSwipe: MonthSwipe(
                timing: Timing(duration: 0.30, curve: .easeInOut),
                mode: .horizontalSlide
            ),
            backgroundTreatment: .publicVisualEffect
        )
    }()

    static let immediate: ChatSearchAnimationSpec = production.replacingDurations(with: 0)

    func resolved(for preferences: AccessibilityPreferences) -> ChatSearchAnimationSpec {
        var result = self
        if preferences.reduceMotion {
            result = reducedMotionSpec()
        }
        if preferences.reduceTransparency {
            result = result.replacingTransparencyEffects()
        }
        return result
    }

    private func reducedMotionSpec() -> ChatSearchAnimationSpec {
        let fadeIn = Timing(duration: 0.15, curve: .easeOut)
        let fadeOut = Timing(duration: 0.15, curve: .easeOut)
        return ChatSearchAnimationSpec(
            floatingButtons: Transition(
                alpha: ScalarTransition(from: 0, to: 1, timing: fadeIn)
            ),
            list: ListTransitions(
                presentation: Transition(
                    alpha: ScalarTransition(from: 0, to: 1, timing: fadeIn)
                ),
                dismissal: Transition(
                    alpha: ScalarTransition(from: 1, to: 0, timing: fadeOut)
                )
            ),
            calendar: CalendarTransitions(
                dimPresentation: Transition(
                    alpha: ScalarTransition(from: 0, to: 1, timing: fadeIn)
                ),
                sheetPresentation: Transition(
                    alpha: ScalarTransition(from: 0, to: 1, timing: fadeIn)
                ),
                dimDismissal: Transition(
                    alpha: ScalarTransition(from: 1, to: 0, timing: fadeOut)
                ),
                sheetDismissal: Transition(
                    alpha: ScalarTransition(from: 1, to: 0, timing: fadeOut)
                )
            ),
            monthSwipe: MonthSwipe(timing: fadeIn, mode: .crossfade),
            backgroundTreatment: backgroundTreatment,
            isReducedMotion: true
        )
    }

    private func replacingTransparencyEffects() -> ChatSearchAnimationSpec {
        ChatSearchAnimationSpec(
            floatingButtons: floatingButtons.withoutBlur(),
            list: ListTransitions(
                presentation: list.presentation.withoutBlur(),
                dismissal: list.dismissal.withoutBlur()
            ),
            calendar: CalendarTransitions(
                dimPresentation: calendar.dimPresentation.withoutBlur(),
                sheetPresentation: calendar.sheetPresentation.withoutBlur(),
                dimDismissal: calendar.dimDismissal.withoutBlur(),
                sheetDismissal: calendar.sheetDismissal.withoutBlur()
            ),
            monthSwipe: monthSwipe,
            backgroundTreatment: .opaqueSystemMaterial,
            isReducedMotion: isReducedMotion
        )
    }

    private func replacingDurations(with duration: TimeInterval) -> ChatSearchAnimationSpec {
        ChatSearchAnimationSpec(
            floatingButtons: floatingButtons.replacingDuration(with: duration),
            list: ListTransitions(
                presentation: list.presentation.replacingDuration(with: duration),
                dismissal: list.dismissal.replacingDuration(with: duration)
            ),
            calendar: CalendarTransitions(
                dimPresentation: calendar.dimPresentation.replacingDuration(with: duration),
                sheetPresentation: calendar.sheetPresentation.replacingDuration(with: duration),
                dimDismissal: calendar.dimDismissal.replacingDuration(with: duration),
                sheetDismissal: calendar.sheetDismissal.replacingDuration(with: duration)
            ),
            monthSwipe: MonthSwipe(
                timing: monthSwipe.timing.replacingDuration(with: duration),
                mode: monthSwipe.mode
            ),
            backgroundTreatment: backgroundTreatment,
            isReducedMotion: isReducedMotion
        )
    }
}
