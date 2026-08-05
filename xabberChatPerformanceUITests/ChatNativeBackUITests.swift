//
//  ChatNativeBackUITests.swift
//  xabberChatPerformanceUITests
//
//  Created by Codex on 01.08.2026.
//  Copyright © 2026 Igor Boldin. All rights reserved.
//

import XCTest

/// Exact V11 acceptance through the real production-shaped route:
/// XabberTabBar -> UINavigationController -> LastChats row selection -> Chat.
final class ChatNativeBackUITests: XCTestCase {
    private enum Accessibility {
        static let tabShell = "chat-performance-tab-shell"
        static let navigationShell =
            "chat-performance-last-chats-navigation-shell"
        static let lastChatsScreen = "chat-performance-last-chats-screen"
        static let row = "chat-performance-last-chats-row"
        static let chatScreen = "chat.performance.screen"
    }

    /// iOS 26 renders the native navigation Back item through a private
    /// portal. The chevron remains visible and interactive, but the generated
    /// button is absent from XCUI's accessibility element tree. Keep the
    /// literal tap inside UIKit's leading 44-point target instead of replacing
    /// the system item with a test-only custom button.
    private let nativeBackTapInset: CGFloat = 30

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = [
            "--xabber-chat-performance-fixture",
            "small",
            "--xabber-chat-manual-native-back"
        ]
        app.launchEnvironment = ["XABBER_CHAT_PERFORMANCE_UI_TEST": "1"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        XCUIDevice.shared.orientation = .portrait
    }

    func testChevronOnlyBackMeetsHitTargetAndSupportsTapAndSuccessfulEdgeSwipe() {
        let tabShell = element(identifier: Accessibility.tabShell)
        let navigationShell = element(identifier: Accessibility.navigationShell)
        let lastChatsScreen = element(identifier: Accessibility.lastChatsScreen)
        let row = element(identifier: Accessibility.row)
        XCTAssertTrue(tabShell.waitForExistence(timeout: 5))
        XCTAssertTrue(navigationShell.waitForExistence(timeout: 5))
        XCTAssertTrue(lastChatsScreen.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(row, timeout: 5))
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(identifier: Accessibility.row).count,
            1,
            "the manual route must expose exactly one ordinary Last Chats row"
        )

        let sourceNavigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(sourceNavigationBar.exists)
        let sourceNavigationLabels = Array(Set(
            sourceNavigationBar.staticTexts.allElementsBoundByIndex
                .filter { $0.exists && !$0.label.isEmpty }
                .map(\.label) +
            [sourceNavigationBar.label].filter { !$0.isEmpty }
        ))

        XCTContext.runActivity(named: "Native Back tap") { _ in
            row.tap()
            let chatScreen = element(identifier: Accessibility.chatScreen)
            XCTAssertTrue(chatScreen.waitForExistence(timeout: 5))
            assertChevronOnlyNativeBack(
                in: sourceNavigationBar,
                sourceNavigationLabels: sourceNavigationLabels
            )

            tapNativeBack(in: sourceNavigationBar)
            XCTAssertTrue(lastChatsScreen.waitForExistence(timeout: 5))
            XCTAssertTrue(waitUntilHittable(row, timeout: 5))
            XCTAssertTrue(waitForNonExistence(chatScreen, timeout: 5))
            XCTAssertEqual(
                app.descendants(matching: .any)
                    .matching(identifier: Accessibility.row).count,
                1,
                "Back must return to the same single-row Last Chats host without duplicating the route"
            )
        }

        XCTContext.runActivity(named: "Successful system-edge swipe") { _ in
            row.tap()
            let chatScreen = element(identifier: Accessibility.chatScreen)
            XCTAssertTrue(chatScreen.waitForExistence(timeout: 5))
            assertChevronOnlyNativeBack(
                in: sourceNavigationBar,
                sourceNavigationLabels: sourceNavigationLabels
            )

            let start = app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.002, dy: 0.5)
            )
            let end = app.coordinate(
                withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5)
            )
            start.press(forDuration: 0.05, thenDragTo: end)

            XCTAssertTrue(lastChatsScreen.waitForExistence(timeout: 5))
            XCTAssertTrue(waitUntilHittable(row, timeout: 5))
            XCTAssertTrue(waitForNonExistence(chatScreen, timeout: 5))
            XCTAssertEqual(
                app.descendants(matching: .any)
                    .matching(identifier: Accessibility.row).count,
                1,
                "the successful system-edge pop must return to the original Last Chats stack"
            )
            XCTAssertEqual(app.state, .runningForeground)
        }
    }

    private func assertChevronOnlyNativeBack(
        in navigationBar: XCUIElement,
        sourceNavigationLabels: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntilHittable(navigationBar, timeout: 5),
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            navigationBar.frame.height,
            44,
            "the coordinate tap must remain inside UIKit's minimum-height native navigation target",
            file: file,
            line: line
        )
        let leadingBackRegion = CGRect(
            x: navigationBar.frame.minX,
            y: navigationBar.frame.minY,
            width: min(60, navigationBar.frame.width),
            height: navigationBar.frame.height
        )
        let visibleLeadingTitles = navigationBar.staticTexts.allElementsBoundByIndex
            .filter { element in
                element.exists &&
                    element.frame.width > 0 &&
                    element.frame.height > 0 &&
                    element.frame.intersects(leadingBackRegion)
            }
            .map(\.label)
        XCTAssertTrue(
            visibleLeadingTitles.isEmpty,
            "the leading navigation affordance must render only the chevron: \(visibleLeadingTitles)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            Set(sourceNavigationLabels).isDisjoint(with: Set(visibleLeadingTitles)),
            "the source title must never be rendered beside the chevron",
            file: file,
            line: line
        )
    }

    private func tapNativeBack(
        in navigationBar: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(navigationBar.exists, file: file, line: line)
        XCTAssertGreaterThan(
            navigationBar.frame.width,
            nativeBackTapInset,
            file: file,
            line: line
        )
        navigationBar.coordinate(
            withNormalizedOffset: CGVector(
                dx: nativeBackTapInset / navigationBar.frame.width,
                dy: 0.5
            )
        ).tap()
    }

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitUntilHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && element.isHittable
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForNonExistence(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return !element.exists
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
