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
//

import UIKit
import MaterialComponents.MDCPalettes

class SkeletonMessageCell: MessageContentCell, ChatOffscreenWorkManaging {
    static let staticPlaceholderAlpha: CGFloat = 0.42
    static var reduceMotionOverrideForTesting: Bool?

    private static let animationKey = "xabber.chat.skeleton.opacity"
    private var isConfiguredForSkeletonAnimation = false
    private(set) var skeletonAnimationStartCount = 0

    var activeSkeletonAnimationCount: Int {
        messageContainerView.layer.animation(forKey: Self.animationKey) == nil ? 0 : 1
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isConfiguredForSkeletonAnimation = false
        stopSkeletonAnimation()
    }

    override func configure(with message: MessageType, at indexPath: IndexPath, and messagesCollectionView: MessagesCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        updateAnimationVisibility(
            isVisible: true,
            reduceMotion: Self.reduceMotionOverrideForTesting ?? UIAccessibility.isReduceMotionEnabled
        )
    }

    func updateAnimationVisibility(isVisible: Bool, reduceMotion: Bool) {
        if isVisible {
            isConfiguredForSkeletonAnimation = true
        }
        messageContainerView.alpha = Self.staticPlaceholderAlpha
        guard isVisible, !reduceMotion else {
            stopSkeletonAnimation()
            return
        }
        guard messageContainerView.layer.animation(forKey: Self.animationKey) == nil else {
            return
        }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.35
        animation.toValue = 0.5
        animation.duration = 0.66
        animation.beginTime = CACurrentMediaTime() + 0.5
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = true
        messageContainerView.layer.add(animation, forKey: Self.animationKey)
        skeletonAnimationStartCount += 1
    }

    func cancelOffscreenWork() {
        stopSkeletonAnimation()
    }

    func resumeOnscreenWork() {
        guard isConfiguredForSkeletonAnimation else { return }
        updateAnimationVisibility(
            isVisible: true,
            reduceMotion: Self.reduceMotionOverrideForTesting ?? UIAccessibility.isReduceMotionEnabled
        )
    }

    private func stopSkeletonAnimation() {
        messageContainerView.layer.removeAnimation(forKey: Self.animationKey)
        messageContainerView.alpha = Self.staticPlaceholderAlpha
    }

    override func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        false
    }
}
