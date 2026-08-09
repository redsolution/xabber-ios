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

    func testChatComposerStartsAtSafeAreaUntilKeyboardActuallyAppears() throws {
        let controller = makeLoadedChatController()

        let safeAreaConstraint = try XCTUnwrap(controller.xabberInputViewBottomConstraint)
        XCTAssertTrue(safeAreaConstraint.isActive)
        XCTAssertEqual(safeAreaConstraint.relation, .equal)
        XCTAssertTrue(safeAreaConstraint.secondItem === controller.view.safeAreaLayoutGuide)
        XCTAssertFalse(try XCTUnwrap(controller.xabberInputViewKeyboardTopConstraint).isActive)
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
        XCTAssertFalse(keyboardTopConstraint.isActive)
        XCTAssertTrue(try XCTUnwrap(controller.xabberInputViewBottomConstraint).isActive)
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
        XCTAssertEqual(
            controller.updateChatInputViewForCurrentKeyboardLayout(visibleKeyboardHeight: 300),
            ModernXabberInputView.defaultBarHeight + 300,
            accuracy: 0.001
        )
    }

    func testComposerKeepsFollowingKeyboardUntilDidHideThenReturnsToSafeArea() throws {
        let controller = makeLoadedChatController()
        let visibleFrame = CGRect(x: 0, y: 544, width: 390, height: 300)

        controller.keyboardWillShowNotification(keyboardNotification(
            name: UIResponder.keyboardWillShowNotification,
            frame: visibleFrame
        ))
        XCTAssertFalse(try XCTUnwrap(controller.xabberInputViewBottomConstraint).isActive)
        XCTAssertTrue(try XCTUnwrap(controller.xabberInputViewKeyboardTopConstraint).isActive)

        controller.keyboardWillHideNotification(keyboardNotification(
            name: UIResponder.keyboardWillHideNotification,
            frame: CGRect(x: 0, y: 844, width: 390, height: 300)
        ) as NSNotification)
        XCTAssertFalse(try XCTUnwrap(controller.xabberInputViewBottomConstraint).isActive)
        XCTAssertTrue(try XCTUnwrap(controller.xabberInputViewKeyboardTopConstraint).isActive)

        controller.keyboardDidHideNotification(Notification(
            name: UIResponder.keyboardDidHideNotification
        ))
        XCTAssertTrue(try XCTUnwrap(controller.xabberInputViewBottomConstraint).isActive)
        XCTAssertFalse(try XCTUnwrap(controller.xabberInputViewKeyboardTopConstraint).isActive)
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

    func testDefaultCollectionInsetUsesComposerActualTopBoundary() throws {
        let controller = makeLoadedChatController()
        try XCTUnwrap(controller.xabberInputViewBottomConstraint).isActive = false
        try XCTUnwrap(controller.xabberInputViewKeyboardTopConstraint).isActive = false
        controller.xabberInputView.frame = CGRect(
            x: controller.xabberInputView.frame.minX,
            y: controller.view.bounds.maxY - 120,
            width: controller.xabberInputView.bounds.width,
            height: ModernXabberInputView.defaultBarHeight
        )

        controller.updateChatCollectionInsets()

        XCTAssertEqual(
            controller.messagesCollectionView.contentInset.bottom,
            120 + ChatFloatingHeaderLayoutPolicy.composerMessageSpacing,
            accuracy: 0.001
        )
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

    private func keyboardNotification(name: Notification.Name, frame: CGRect) -> Notification {
        Notification(
            name: name,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame),
                UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0)
            ]
        )
    }
}
