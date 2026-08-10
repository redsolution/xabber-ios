//
//  SearchChatListKeyboardLayoutTests.swift
//  xabberTests
//
//  Created by Codex on 08.07.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest
import UIKit
@testable import xabber

@MainActor
final class SearchChatListKeyboardLayoutTests: XCTestCase {
    func testKeyboardLayoutUpdatePolicySkipsEquivalentUIKitNotifications() {
        let signature = ChatKeyboardLayoutUpdateSignature(
            visibleHeight: 300,
            viewSize: CGSize(width: 390, height: 844),
            searchOwnsKeyboard: false
        )

        XCTAssertTrue(ChatKeyboardLayoutUpdatePolicy.shouldApply(previous: nil, next: signature))
        XCTAssertFalse(ChatKeyboardLayoutUpdatePolicy.shouldApply(previous: signature, next: signature))
        XCTAssertTrue(ChatKeyboardLayoutUpdatePolicy.shouldApply(
            previous: signature,
            next: ChatKeyboardLayoutUpdateSignature(
                visibleHeight: 301,
                viewSize: signature.viewSize,
                searchOwnsKeyboard: false
            )
        ))
        XCTAssertTrue(ChatKeyboardLayoutUpdatePolicy.shouldApply(
            previous: signature,
            next: ChatKeyboardLayoutUpdateSignature(
                visibleHeight: signature.visibleHeight,
                viewSize: signature.viewSize,
                searchOwnsKeyboard: true
            )
        ))
    }

    func testBottomBarIsAnchoredToKeyboardLayoutGuide() throws {
        let controller = SearchChatListViewController()

        controller.loadViewIfNeeded()
        controller.activateConstraints()

        let bottomConstraint = try XCTUnwrap(controller.bottomBarBottomConstraint)
        XCTAssertTrue(bottomConstraint.firstItem === controller.bottomBar)
        XCTAssertEqual(bottomConstraint.firstAttribute, .bottom)
        XCTAssertTrue(bottomConstraint.secondItem === controller.view.keyboardLayoutGuide)
        XCTAssertEqual(bottomConstraint.secondAttribute, .top)
        XCTAssertEqual(bottomConstraint.constant, 0)

        let heightConstraint = try XCTUnwrap(controller.bottomBarHeightConstraint)
        XCTAssertTrue(heightConstraint.firstItem === controller.bottomBar)
        XCTAssertEqual(heightConstraint.firstAttribute, .height)
        XCTAssertEqual(heightConstraint.constant, ModernXabberInputView.defaultBarHeight, accuracy: 0.001)
    }

    func testSafeAreaIsNotAddedToExternallyAnchoredComposerHeight() {
        XCTAssertEqual(
            ModernXabberInputView.resolvedContainerHeight(
                barHeight: ModernXabberInputView.defaultBarHeight,
                keyboardHeight: 0,
                topInset: 0,
                bottomSafeAreaInset: 34,
                includeBottomSafeAreaWhenKeyboardHidden: false
            ),
            ModernXabberInputView.defaultBarHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ModernXabberInputView.resolvedContainerHeight(
                barHeight: ModernXabberInputView.defaultBarHeight,
                keyboardHeight: 0,
                topInset: 0,
                bottomSafeAreaInset: 34,
                includeBottomSafeAreaWhenKeyboardHidden: true
            ),
            ModernXabberInputView.defaultBarHeight + 34,
            accuracy: 0.001
        )
    }

    func testChatSearchStatusBarIsKeyboardOwnedWithoutKeyboardHeightTail() throws {
        let controller = makeLoadedChatController()

        controller.inSearchMode.accept(true)
        controller.configureSearchModeForCurrentActivation(
            defaultActivateKeyboard: false,
            defaultAnimated: false
        )
        controller.keyboardWillChangeFrameNotification(
            Notification(
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey: NSValue(
                        cgRect: CGRect(x: 0, y: 544, width: 390, height: 300)
                    ),
                    UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0)
                ]
            )
        )
        controller.view.layoutIfNeeded()

        let keyboardTopConstraint = try XCTUnwrap(controller.xabberInputViewKeyboardTopConstraint)
        XCTAssertTrue(keyboardTopConstraint.isActive)
        XCTAssertTrue(keyboardTopConstraint.firstItem === controller.xabberInputView)
        XCTAssertEqual(keyboardTopConstraint.firstAttribute, .bottom)
        XCTAssertTrue(keyboardTopConstraint.secondItem === controller.view.keyboardLayoutGuide)
        XCTAssertEqual(keyboardTopConstraint.secondAttribute, .top)

        XCTAssertFalse(try XCTUnwrap(controller.xabberInputViewBottomConstraint).isActive)
        XCTAssertEqual(controller.xabberInputView.keyboardHeight, 0, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(controller.xabberInputView.heightConstraint).constant,
            ModernXabberInputView.defaultBarHeight,
            accuracy: 0.001
        )
        controller.xabberInputView.updateBottomPanels(withOffset: 0)
        XCTAssertEqual(
            controller.xabberInputView.searchPanel.frame.height,
            ChatSearchBottomActionBarLayout.height,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.xabberInputView.searchPanel.frame.midY,
            NativeGlassBarStyle.minimumHeight / 2,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(
            controller.xabberInputView.searchPanel.frame.maxY,
            controller.xabberInputView.bounds.maxY
        )
    }

    func testChatSearchStatusBarStaysKeyboardOwnedAfterContainerBoundsChange() throws {
        let controller = makeLoadedChatController()

        controller.inSearchMode.accept(true)
        controller.configureSearchModeForCurrentActivation(
            defaultActivateKeyboard: false,
            defaultAnimated: false
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 812)
        controller.shouldChangeFrame()
        controller.view.layoutIfNeeded()

        let keyboardTopConstraint = try XCTUnwrap(controller.xabberInputViewKeyboardTopConstraint)
        XCTAssertTrue(keyboardTopConstraint.isActive)
        XCTAssertFalse(try XCTUnwrap(controller.xabberInputViewBottomConstraint).isActive)
        XCTAssertEqual(controller.xabberInputView.keyboardHeight, 0, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(controller.xabberInputView.heightConstraint).constant,
            ModernXabberInputView.defaultBarHeight,
            accuracy: 0.001
        )
        controller.xabberInputView.updateBottomPanels(withOffset: 0)
        XCTAssertEqual(
            controller.xabberInputView.searchPanel.frame.height,
            ChatSearchBottomActionBarLayout.height,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.xabberInputView.searchPanel.frame.midY,
            NativeGlassBarStyle.minimumHeight / 2,
            accuracy: 0.001
        )
    }

    func testNormalChatComposerIsKeyboardOwnedWithoutKeyboardHeightTail() throws {
        let controller = makeLoadedChatController()

        controller.keyboardWillChangeFrameNotification(
            Notification(
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey: NSValue(
                        cgRect: CGRect(x: 0, y: 544, width: 390, height: 300)
                    ),
                    UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0)
                ]
            )
        )
        controller.view.layoutIfNeeded()

        let keyboardTopConstraint = try XCTUnwrap(controller.xabberInputViewKeyboardTopConstraint)
        XCTAssertTrue(keyboardTopConstraint.isActive)
        XCTAssertTrue(keyboardTopConstraint.firstItem === controller.xabberInputView)
        XCTAssertEqual(keyboardTopConstraint.firstAttribute, .bottom)
        XCTAssertTrue(keyboardTopConstraint.secondItem === controller.view.keyboardLayoutGuide)
        XCTAssertEqual(keyboardTopConstraint.secondAttribute, .top)
        XCTAssertFalse(try XCTUnwrap(controller.xabberInputViewBottomConstraint).isActive)
        XCTAssertEqual(controller.xabberInputView.keyboardHeight, 0, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(controller.xabberInputView.heightConstraint).constant,
            ModernXabberInputView.defaultBarHeight,
            accuracy: 0.001
        )
    }

    func testAutoLayoutOwnedComposerSetupFramesDoesNotOverrideGuidePosition() {
        let controller = makeLoadedChatController()
        let originalFrame = controller.xabberInputView.frame

        controller.xabberInputView.setupFrames(
            CGRect(
                x: originalFrame.minX,
                y: 0,
                width: originalFrame.width,
                height: originalFrame.height
            )
        )

        XCTAssertEqual(controller.xabberInputView.frame, originalFrame)
    }

    func testNormalComposerSequentialKeyboardFramesUpdateCollectionClearance() {
        let controller = makeLoadedChatController()
        let overlaps: [CGFloat] = [300, 164, 84, 0]

        for overlap in overlaps {
            controller.keyboardWillChangeFrameNotification(
                Notification(
                    name: UIResponder.keyboardWillChangeFrameNotification,
                    object: nil,
                    userInfo: [
                        UIResponder.keyboardFrameEndUserInfoKey: NSValue(
                            cgRect: CGRect(
                                x: 0,
                                y: controller.view.bounds.height - overlap,
                                width: controller.view.bounds.width,
                                height: 300
                            )
                        ),
                        UIResponder.keyboardAnimationDurationUserInfoKey:
                            NSNumber(value: 0)
                    ]
                )
            )

            let metrics = controller.currentChatComposerKeyboardLayoutMetrics()
            XCTAssertEqual(
                controller.messagesCollectionView.contentInset.bottom,
                metrics.collectionObstructionHeight +
                    ChatFloatingHeaderLayoutPolicy.composerMessageSpacing,
                accuracy: 0.001,
                "Unexpected collection clearance for overlap \(overlap)"
            )
        }
    }

    func testContextPreviewKeepsComposerVisualHeightFreeOfKeyboardAndSafeAreaTail() throws {
        let controller = makeLoadedChatController()
        controller.keyboardWillChangeFrameNotification(
            Notification(
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey: NSValue(
                        cgRect: CGRect(x: 0, y: 544, width: 390, height: 300)
                    ),
                    UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0)
                ]
            )
        )

        controller.xabberInputView.showEditPanel()
        controller.view.layoutIfNeeded()

        let visualHeight = try XCTUnwrap(
            controller.xabberInputView.heightConstraint
        ).constant
        XCTAssertEqual(controller.xabberInputView.keyboardHeight, 0, accuracy: 0.001)
        XCTAssertEqual(
            visualHeight,
            controller.xabberInputView.barHeight + controller.xabberInputView.topInset,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.messagesCollectionView.contentInset.bottom,
            visualHeight + 300 + ChatFloatingHeaderLayoutPolicy.composerMessageSpacing,
            accuracy: 0.001
        )
    }

    func testChatComposerRemainsAnchoredToKeyboardGuideAfterSearchReset() throws {
        let controller = makeLoadedChatController()

        controller.inSearchMode.accept(true)
        controller.configureSearchModeForCurrentActivation(
            defaultActivateKeyboard: false,
            defaultAnimated: false
        )
        XCTAssertEqual(controller.xabberInputView.state, .search)

        controller.inSearchMode.accept(false)
        controller.keyboardWillChangeFrameNotification(
            Notification(
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                userInfo: [
                    UIResponder.keyboardFrameEndUserInfoKey: NSValue(
                        cgRect: CGRect(x: 0, y: 544, width: 390, height: 300)
                    ),
                    UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0)
                ]
            )
        )
        controller.view.layoutIfNeeded()

        XCTAssertEqual(controller.xabberInputView.state, .normal)
        XCTAssertFalse(try XCTUnwrap(controller.xabberInputViewBottomConstraint).isActive)
        XCTAssertTrue(try XCTUnwrap(controller.xabberInputViewKeyboardTopConstraint).isActive)
        XCTAssertEqual(controller.xabberInputView.keyboardHeight, 0, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(controller.xabberInputView.heightConstraint).constant,
            ModernXabberInputView.defaultBarHeight,
            accuracy: 0.001
        )
        let metrics = controller.updateChatInputViewForCurrentKeyboardLayout(
            visibleKeyboardHeight: 300
        )
        XCTAssertEqual(
            metrics.visualHeight,
            ModernXabberInputView.defaultBarHeight,
            accuracy: 0.001
        )
        XCTAssertEqual(
            metrics.collectionObstructionHeight,
            ModernXabberInputView.defaultBarHeight + 300,
            accuracy: 0.001
        )
    }

    func testInteractiveKeyboardMotionSkipsNestedAnimationUntilDragFinishes() {
        let interactiveUpdate = ChatKeyboardMotionPolicy.isInteractiveUpdate(
            usesInteractiveDismissMode: true,
            isTracking: true,
            isDragging: true
        )

        XCTAssertTrue(interactiveUpdate)
        XCTAssertFalse(
            ChatSearchMotionMutationPolicy.shouldAnimate(
                requestedAnimated: true,
                isNavigationTransitionActive: false,
                isPreparingFirstFrame: false,
                isInteractiveKeyboardUpdate: interactiveUpdate
            )
        )

        let settledUpdate = ChatKeyboardMotionPolicy.isInteractiveUpdate(
            usesInteractiveDismissMode: true,
            isTracking: false,
            isDragging: false
        )
        XCTAssertFalse(settledUpdate)
        XCTAssertTrue(
            ChatSearchMotionMutationPolicy.shouldAnimate(
                requestedAnimated: true,
                isNavigationTransitionActive: false,
                isPreparingFirstFrame: false,
                isInteractiveKeyboardUpdate: settledUpdate
            )
        )
    }

    func testKeyboardMotionIsNotInteractiveForNonInteractiveDismissMode() {
        XCTAssertFalse(
            ChatKeyboardMotionPolicy.isInteractiveUpdate(
                usesInteractiveDismissMode: false,
                isTracking: true,
                isDragging: true
            )
        )
    }

    func testUndockedKeyboardDoesNotCreateBottomObstruction() {
        XCTAssertEqual(
            ChatViewController.keyboardOverlapHeight(
                viewBounds: CGRect(x: 0, y: 0, width: 1024, height: 1366),
                keyboardFrameInView: CGRect(x: 540, y: 720, width: 420, height: 320)
            ),
            0,
            accuracy: 0.001
        )
    }

    func testConstraintManagedComposerUpdateDoesNotOverrideItsResolvedFrame() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let inputView = ModernXabberInputView(frame: .zero)
        inputView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inputView)

        let heightConstraint = inputView.heightAnchor.constraint(
            equalToConstant: ModernXabberInputView.defaultBarHeight
        )
        inputView.heightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            inputView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            inputView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            inputView.bottomAnchor.constraint(equalTo: container.topAnchor, constant: 500),
            heightConstraint
        ])
        container.layoutIfNeeded()
        let resolvedFrame = inputView.frame

        inputView.update(
            screenHeight: container.bounds.height,
            keyboardHeight: 0,
            includeBottomSafeAreaWhenKeyboardHidden: false
        )

        XCTAssertEqual(inputView.frame, resolvedFrame)
    }

    private func makeLoadedChatController() -> ChatViewController {
        let controller = ChatViewController()
        controller.owner = "owner@example.com"
        controller.jid = "alexey.boldin@example.com"
        controller.conversationType = .regular
        controller.ownerSender = Sender(id: controller.owner, displayName: "Owner")
        controller.opponentSender = Sender(id: controller.jid, displayName: "Alexey Boldin")
        controller.showSkeletonObserver.accept(false)

        let navigationController = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()

        return controller
    }
}
