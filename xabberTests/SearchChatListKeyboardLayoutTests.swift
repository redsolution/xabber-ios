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
    }

    func testChatComposerReturnsToNormalKeyboardLayoutImmediatelyAfterSearchReset() throws {
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
        XCTAssertTrue(try XCTUnwrap(controller.xabberInputViewBottomConstraint).isActive)
        XCTAssertFalse(try XCTUnwrap(controller.xabberInputViewKeyboardTopConstraint).isActive)
        XCTAssertEqual(controller.xabberInputView.keyboardHeight, 300, accuracy: 0.001)
        XCTAssertGreaterThan(
            try XCTUnwrap(controller.xabberInputView.heightConstraint).constant,
            ModernXabberInputView.defaultBarHeight + 250
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
}
