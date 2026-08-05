//
//  BottomOverlayInsetCoordinator.swift
//  xabber
//

import UIKit

enum RootBottomBarInsetPolicy {
    static let clearance: CGFloat = 12
    static let bottomTolerance: CGFloat = 2

    static func requiredBottomContribution(
        containerMaxY: CGFloat,
        visibleOverlayFrames: [CGRect],
        systemBottomContribution: CGFloat,
        baselineBottomInset: CGFloat,
        clearance: CGFloat = clearance
    ) -> CGFloat {
        guard let topmostOverlayMinY = visibleOverlayFrames.map(\.minY).min() else {
            return 0
        }

        let requiredAdjustedBottomInset = max(
            0,
            containerMaxY - topmostOverlayMinY + clearance
        )
        return max(
            0,
            requiredAdjustedBottomInset - systemBottomContribution - baselineBottomInset
        )
    }

    static func adjustedContentOffsetY(
        currentY: CGFloat,
        oldMinimumY: CGFloat,
        oldMaximumY: CGFloat,
        newMinimumY: CGFloat,
        newMaximumY: CGFloat,
        bottomTolerance: CGFloat = bottomTolerance
    ) -> CGFloat {
        let wasAtBottom = abs(currentY - oldMaximumY) <= bottomTolerance
        if wasAtBottom {
            return newMaximumY
        }

        return min(max(currentY, newMinimumY), newMaximumY)
    }

    static func contentOffsetRange(
        contentSizeHeight: CGFloat,
        boundsHeight: CGFloat,
        adjustedInsets: UIEdgeInsets
    ) -> ClosedRange<CGFloat> {
        let minimumY = -adjustedInsets.top
        let maximumY = max(
            minimumY,
            contentSizeHeight + adjustedInsets.bottom - boundsHeight
        )
        return minimumY...maximumY
    }
}

final class BottomOverlayInsetCoordinator {
    private(set) var appliedBottomContribution: CGFloat = 0

    func apply(
        to scrollView: UIScrollView,
        in containerView: UIView,
        overlays: [UIView],
        clearance: CGFloat = RootBottomBarInsetPolicy.clearance
    ) {
        guard let containerWindow = containerView.window,
              scrollView.window === containerWindow else {
            return
        }

        scrollView.layoutIfNeeded()

        let oldRange = RootBottomBarInsetPolicy.contentOffsetRange(
            contentSizeHeight: scrollView.contentSize.height,
            boundsHeight: scrollView.bounds.height,
            adjustedInsets: scrollView.adjustedContentInset
        )
        let oldOffsetY = scrollView.contentOffset.y
        let baselineContentBottom = scrollView.contentInset.bottom - appliedBottomContribution
        let baselineIndicatorBottom = scrollView.verticalScrollIndicatorInsets.bottom - appliedBottomContribution
        let systemBottomContribution = max(
            0,
            scrollView.adjustedContentInset.bottom - scrollView.contentInset.bottom
        )
        let visibleOverlayFrames = overlays.compactMap { overlay -> CGRect? in
            guard overlay.superview != nil,
                  !overlay.isHidden,
                  overlay.alpha > 0.01,
                  overlay.bounds.width > 0,
                  overlay.bounds.height > 0,
                  overlay.isDescendant(of: containerView) else {
                return nil
            }
            return overlay.convert(overlay.bounds, to: containerView)
        }
        let contribution = RootBottomBarInsetPolicy.requiredBottomContribution(
            containerMaxY: containerView.bounds.maxY,
            visibleOverlayFrames: visibleOverlayFrames,
            systemBottomContribution: systemBottomContribution,
            baselineBottomInset: baselineContentBottom,
            clearance: clearance
        )
        let newContentBottom = baselineContentBottom + contribution
        let newIndicatorBottom = baselineIndicatorBottom + contribution

        let contentInsetNeedsUpdate = abs(scrollView.contentInset.bottom - newContentBottom) > 0.001
        let indicatorInsetNeedsUpdate = abs(
            scrollView.verticalScrollIndicatorInsets.bottom - newIndicatorBottom
        ) > 0.001

        appliedBottomContribution = contribution
        guard contentInsetNeedsUpdate || indicatorInsetNeedsUpdate else { return }

        UIView.performWithoutAnimation {
            if contentInsetNeedsUpdate {
                var contentInset = scrollView.contentInset
                contentInset.bottom = newContentBottom
                scrollView.contentInset = contentInset
            }
            if indicatorInsetNeedsUpdate {
                var indicatorInsets = scrollView.verticalScrollIndicatorInsets
                indicatorInsets.bottom = newIndicatorBottom
                scrollView.verticalScrollIndicatorInsets = indicatorInsets
            }

            scrollView.layoutIfNeeded()
            let newRange = RootBottomBarInsetPolicy.contentOffsetRange(
                contentSizeHeight: scrollView.contentSize.height,
                boundsHeight: scrollView.bounds.height,
                adjustedInsets: scrollView.adjustedContentInset
            )
            let newOffsetY = RootBottomBarInsetPolicy.adjustedContentOffsetY(
                currentY: oldOffsetY,
                oldMinimumY: oldRange.lowerBound,
                oldMaximumY: oldRange.upperBound,
                newMinimumY: newRange.lowerBound,
                newMaximumY: newRange.upperBound
            )
            if abs(scrollView.contentOffset.y - newOffsetY) > 0.001 {
                scrollView.contentOffset.y = newOffsetY
            }
        }
    }
}
