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
}
